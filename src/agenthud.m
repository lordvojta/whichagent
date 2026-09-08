// agenthud: on-screen banners for coding-agent events, needing no notification
// permission.
//
//   agenthud <title> <subtitle> <body> <image|""> <click-cmd|""> [seconds]
//   agenthud --daemon     own every banner and lay them out (started on demand)
//   agenthud --stop       fade everything out and exit the daemon
//
// Why a daemon. Each banner used to be its own process that guessed its slot by
// counting the other agenthud processes running. Four processes each guessing
// where the others are cannot lay out a shared stack, and it failed in four
// distinct ways: the slot was computed once and never revisited, so dismissing
// the top banner left a hole; a COUNT is not a free INDEX, so if slot 0 died
// while slot 1 lived the next banner also took slot 1 and landed on top of it;
// two hooks firing together both enumerated before either appeared and picked
// the same slot; and past five they all clamped onto each other.
//
// One process owning every window makes all four go away: it knows the real
// order, does a single layout pass, and animates the survivors up when one
// leaves. It also drops the process-enumeration cost that used to run on every
// single notification.
//
// The panel is deliberately non-activating so it never steals focus mid-typing,
// which also means it can never receive key events. The global shortcuts live in
// Hammerspoon (~/.hammerspoon/agenthud.lua) and reach us via SIGTERM.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/file.h>

static const NSInteger kMaxVisible = 5;     // past this, the oldest is retired
static const CGFloat   kMargin     = 16;
static const CGFloat   kStackGap   = 8;

static BOOL EnvB(const char *name, BOOL fallback) {
    const char *v = getenv(name);
    if (!v || !*v) return fallback;
    return strcmp(v, "0") != 0;
}

static CGFloat EnvF(const char *name, CGFloat fallback) {
    const char *v = getenv(name);
    if (!v || !*v) return fallback;
    double d = atof(v);
    return d > 0 ? (CGFloat)d : fallback;
}

static NSString *StatePath(NSString *leaf) {
    const char *t = getenv("TMPDIR");
    NSString *dir = [NSString stringWithFormat:@"%s/agent-sound", t && *t ? t : "/tmp"];
    dir = [dir stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:leaf];
}

@class HudItem;

// ---------------------------------------------------------------- manager

@interface HudManager : NSObject
@property (nonatomic, strong) NSMutableArray<HudItem *> *items;
- (void)add:(HudItem *)item;
- (void)remove:(HudItem *)item;
- (void)relayoutAnimated:(BOOL)animated;
- (void)dismissAll;
- (void)focusIndex:(NSInteger)n;
- (void)renumber;
- (void)animate:(NSWindow *)win to:(NSRect)target duration:(NSTimeInterval)d;
- (NSArray<NSValue *> *)targetFrames;
@end

static HudManager *gMgr = nil;

// ------------------------------------------------------------------ views

@interface HudView : NSView
@property (nonatomic, weak) HudItem *item;
@property (nonatomic, weak) NSView *closeButton;
@end

// Force-clicking anything in the banner otherwise pops the macOS Look Up
// dictionary panel over it. Overriding quickLookWithEvent: to do nothing is the
// documented way to opt a view out of that gesture.
@interface HudButton : NSButton
@end
@implementation HudButton
- (void)quickLookWithEvent:(NSEvent *)e { (void)e; }
@end

@interface HudItem : NSObject
@property (nonatomic, strong) NSPanel *win;
@property (nonatomic, copy)   NSString *click;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic)         BOOL closing;
// Carried but not rendered yet. Provider is ~100% Claude Code on this machine,
// so the badge space goes to the event, which actually varies. Plumbing it now
// means adding a title-row glyph later is a rendering change only.
@property (nonatomic, copy)   NSString *provider;
@property (nonatomic, weak)   NSTextField *indexLabel;
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                         body:(NSString *)body
                        image:(NSString *)image
                        click:(NSString *)click
                      seconds:(double)secs
                        event:(NSString *)event
                     provider:(NSString *)provider;
- (void)dismiss;
- (void)activateClick;
- (void)setIndex:(NSInteger)n visible:(BOOL)visible;
@end

@implementation HudView
- (void)mouseDown:(NSEvent *)e { (void)e; [self.item activateClick]; }
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in [self.trackingAreas copy]) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
               owner:self userInfo:nil]];
}
- (void)quickLookWithEvent:(NSEvent *)e { (void)e; }
- (void)mouseEntered:(NSEvent *)e { (void)e; self.closeButton.alphaValue = 1.0; }
- (void)mouseExited:(NSEvent *)e  { (void)e; self.closeButton.alphaValue = 0.45; }
@end

// Event badge. The project artwork answers WHICH repo; this answers WHAT
// happened, mirroring the split already used in the audio (timbre = provider,
// melody = event). Without it all three banners look identical at a glance and
// only the subtitle text distinguishes them.
static NSImage *EventSymbol(NSString *event, NSColor **tint) {
    NSString *primary, *fallback;
    if ([event isEqualToString:@"plan"]) {
        primary = @"list.bullet.clipboard.fill"; fallback = @"doc.text.fill";
        *tint = [NSColor systemBlueColor];
    } else if ([event isEqualToString:@"input"]) {
        primary = @"questionmark.circle.fill"; fallback = @"exclamationmark.circle.fill";
        *tint = [NSColor systemOrangeColor];
    } else {
        primary = @"checkmark.circle.fill"; fallback = @"checkmark";
        *tint = [NSColor systemGreenColor];
    }
    NSImage *img = [NSImage imageWithSystemSymbolName:primary accessibilityDescription:nil];
    if (!img) img = [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:nil];
    return img;
}

static NSTextField *Label(NSString *s, CGFloat size, NSColor *c, BOOL bold) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.stringValue = s ?: @"";
    f.bezeled = NO; f.drawsBackground = NO; f.editable = NO; f.selectable = NO;
    f.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    f.textColor = c;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    return f;
}

// ------------------------------------------------------------------- item

@implementation HudItem

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                         body:(NSString *)body
                        image:(NSString *)image
                        click:(NSString *)click
                      seconds:(double)secs
                        event:(NSString *)event
                     provider:(NSString *)provider {
    if (!(self = [super init])) return nil;
    self.click = click;
    self.provider = provider.length ? provider : @"claude";

    // The keybind hint is a fourth text row and needs about 78pt, so the
    // default height grows to fit it rather than silently dropping the repo
    // path to make room. Turning hints off returns the compact size.
    const BOOL hints  = EnvB("AGENT_HUD_HINTS", YES);
    const CGFloat s   = EnvF("AGENT_HUD_SCALE", 1.0);
    const CGFloat W   = EnvF("AGENT_HUD_WIDTH", 320) * s;
    const CGFloat H   = EnvF("AGENT_HUD_HEIGHT", hints ? 80 : 68) * s;
    const CGFloat PAD = 12 * s;
    const CGFloat ICON = MAX(16.0, H - 2 * PAD);

    NSPanel *win = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.level = NSStatusWindowLevel;
    win.opaque = NO;
    win.backgroundColor = [NSColor clearColor];
    win.hasShadow = YES;
    win.ignoresMouseEvents = NO;
    win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorFullScreenAuxiliary |
                             NSWindowCollectionBehaviorStationary;
    self.win = win;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 16 * s;
    bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = 1;
    bg.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.12].CGColor;

    HudView *hit = [[HudView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    hit.item = self;
    [bg addSubview:hit];

    // Above the hit view, so its clicks are not swallowed by click-to-focus.
    CGFloat cb = 15 * s;
    NSButton *close = [[HudButton alloc] initWithFrame:
        NSMakeRect(W - PAD - cb, H - PAD - cb, cb, cb)];
    close.bordered = NO;
    close.title = @"";
    // nil description, not "Dismiss": that string is what the Look Up panel
    // renders. VoiceOver still gets a label from the button itself below.
    close.image = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                            accessibilityDescription:nil];
    close.accessibilityLabel = @"Dismiss";
    close.imageScaling = NSImageScaleProportionallyUpOrDown;
    close.contentTintColor = [NSColor secondaryLabelColor];
    close.alphaValue = 0.45;
    close.target = self;
    close.action = @selector(dismiss);
    [bg addSubview:close positioned:NSWindowAbove relativeTo:hit];
    hit.closeButton = close;

    NSColor *tint = [NSColor systemGreenColor];
    NSImage *badgeImg = EventSymbol(event ?: @"done", &tint);

    CGFloat textX = PAD;
    if (image.length) {
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:image];
        if (img) {
            NSImageView *iv = [[NSImageView alloc]
                initWithFrame:NSMakeRect(PAD, (H - ICON) / 2, ICON, ICON)];
            iv.image = img;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.wantsLayer = YES;
            iv.layer.cornerRadius = ICON * 0.22;
            iv.layer.masksToBounds = YES;
            // A uniform ring in the event colour. Deliberately all four sides:
            // a single coloured edge on a tile is a banned pattern here, and a
            // ring also survives at small scales where a glyph would not.
            iv.layer.borderWidth = MAX(1.0, 1.5 * s);
            iv.layer.borderColor = [tint colorWithAlphaComponent:0.95].CGColor;
            [hit addSubview:iv];

            // Badge, overhanging the icon corner so its size is not capped by
            // the icon. Floored at 11pt: at scale 0.5 a proportional badge
            // would be 9pt and unreadable.
            CGFloat bs = MAX(11.0, ICON * 0.42);
            NSRect ir = iv.frame;
            NSImageView *bv = [[NSImageView alloc] initWithFrame:
                NSMakeRect(NSMaxX(ir) - bs * 0.72, NSMinY(ir) - bs * 0.24, bs, bs)];
            bv.image = badgeImg;
            bv.contentTintColor = tint;
            bv.imageScaling = NSImageScaleProportionallyUpOrDown;
            bv.wantsLayer = YES;
            // Solid disc behind it, otherwise a green tick on green artwork
            // simply disappears.
            bv.layer.backgroundColor = [NSColor colorWithWhite:0.11 alpha:0.96].CGColor;
            bv.layer.cornerRadius = bs / 2;
            bv.layer.borderWidth = MAX(1.0, 1.2 * s);
            bv.layer.borderColor = [NSColor colorWithWhite:0.11 alpha:0.96].CGColor;
            [hit addSubview:bv positioned:NSWindowAbove relativeTo:iv];

            // Index numeral, top-left of the icon. Deliberately the opposite
            // corner from the event badge (bottom-right of the icon) and the
            // far side of the panel from the close button, so all three have
            // their own space at 360x64.
            CGFloat ns = MAX(13.0, ICON * 0.36);
            NSTextField *num = Label(@"", ns * 0.62, [NSColor labelColor], YES);
            num.alignment = NSTextAlignmentCenter;
            num.frame = NSMakeRect(NSMinX(ir) - ns * 0.28,
                                   NSMaxY(ir) - ns * 0.72, ns, ns);
            num.wantsLayer = YES;
            num.layer.backgroundColor = [NSColor colorWithWhite:0.11 alpha:0.96].CGColor;
            num.layer.cornerRadius = ns / 2;
            num.hidden = YES;
            [hit addSubview:num positioned:NSWindowAbove relativeTo:iv];
            self.indexLabel = num;
            textX = PAD + ICON + 10 * s;
        }
    }

    CGFloat tw = W - textX - PAD - cb - 6 * s;
    CGFloat f1 = 12 * s, f2 = 11 * s, f3 = 10 * s, f4 = 9 * s;
    CGFloat h1 = ceil(f1 * 1.42), h2 = ceil(f2 * 1.42);
    CGFloat h3 = ceil(f3 * 1.42), h4 = ceil(f4 * 1.42);
    CGFloat gap = 2 * s, vmargin = 5 * s;

    const char *ht = getenv("AGENT_HUD_HINT_TEXT");
    NSString *hintText = (ht && *ht) ? @(ht)
        : @"⌘⌃↩ open  ·  ⌘⌃⌫ dismiss";

    // Rows are dropped in priority order when they will not fit, never clipped.
    // The repo path outranks the keybind hint: the path is information available
    // nowhere else, the hint is something you stop needing once learned.
    BOOL showBody = body.length > 0;
    BOOL showHint = hints && hintText.length > 0;
    CGFloat need2  = h1 + h2 + gap + 2 * vmargin;
    CGFloat need3  = need2 + h3 + gap;
    CGFloat need2h = need2 + h4 + gap;
    CGFloat need3h = need3 + h4 + gap;
    if (showBody && showHint && need3h > H) showHint = NO;
    if (showBody && need3 > H) showBody = NO;
    if (showHint && (showBody ? need3h : need2h) > H) showHint = NO;

    CGFloat block = h1 + h2 + gap
                  + (showBody ? h3 + gap : 0)
                  + (showHint ? h4 + gap : 0);
    CGFloat top = (H + block) / 2;

    NSTextField *t1 = Label(title, f1, [NSColor labelColor], YES);
    NSTextField *t2 = Label(subtitle, f2, [NSColor secondaryLabelColor], NO);
    t1.frame = NSMakeRect(textX, top - h1, tw, h1);
    t2.frame = NSMakeRect(textX, top - h1 - gap - h2, tw, h2);
    [hit addSubview:t1];
    [hit addSubview:t2];

    CGFloat y = top - h1 - gap - h2;
    if (showBody) {
        NSTextField *t3 = Label(body, f3, [NSColor tertiaryLabelColor], NO);
        t3.frame = NSMakeRect(textX, y - gap - h3, tw, h3);
        [hit addSubview:t3];
        y -= gap + h3;
    }
    if (showHint) {
        NSTextField *t4 = Label(hintText, f4, [NSColor tertiaryLabelColor], NO);
        t4.alignment = NSTextAlignmentRight;
        t4.alphaValue = 0.75;
        t4.frame = NSMakeRect(textX, y - gap - h4, tw, h4);
        [hit addSubview:t4];
    }

    win.contentView = bg;
    win.alphaValue = 0;

    if (secs > 0) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:secs repeats:NO
            block:^(NSTimer *t) { (void)t; [self dismiss]; }];
    }
    return self;
}

- (void)activateClick {
    if (self.click.length) {
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/bin/bash";
        t.arguments = @[@"-lc", self.click];
        @try { [t launch]; } @catch (__unused NSException *ex) {}
    }
    [self dismiss];
}

- (void)setIndex:(NSInteger)n visible:(BOOL)visible {
    // Hidden at a count of one: an index on a lone banner is noise, and the
    // common case should stay clean.
    self.indexLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)n];
    self.indexLabel.hidden = !visible;
}

- (void)dismiss {
    if (self.closing) return;          // the X and the timeout can race
    self.closing = YES;
    [self.timer invalidate];
    self.timer = nil;
    [gMgr remove:self];
}
@end

// ---------------------------------------------------------------- manager

@implementation HudManager

- (instancetype)init {
    if ((self = [super init])) _items = [NSMutableArray array];
    return self;
}

- (void)add:(HudItem *)item {
    // Beyond the visible limit the oldest is retired rather than stacked on top
    // of. With a bottom anchor the oldest sits at the TOP of the stack, so the
    // one that disappears is the one furthest from where the eye is looking.
    while (self.items.count >= kMaxVisible) {
        HudItem *oldest = self.items.firstObject;
        if (!oldest) break;
        [oldest dismiss];
        if (self.items.firstObject == oldest) [self.items removeObjectAtIndex:0];
    }
    [self.items addObject:item];

    [self renumber];
    NSArray<NSValue *> *targets = [self targetFrames];
    if (targets.count != self.items.count) return;
    NSRect final = targets.lastObject.rectValue;

    // Existing banners slide out of the way first.
    for (NSUInteger i = 0; i + 1 < self.items.count; i++) {
        [self animate:self.items[i].win to:targets[i].rectValue duration:0.26];
    }

    // The newcomer rises from under the screen edge rather than fading in on the
    // spot. On a bottom anchored stack a fade reads as an object appearing out
    // of nowhere; sliding up from the edge reads as it arriving.
    NSRect start = final;
    start.origin.y -= (final.size.height + kStackGap);
    [item.win setFrame:start display:NO];
    item.win.alphaValue = 0;
    [item.win orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.34;
        // Fast out of the gate, settling gently. A linear slide looks mechanical.
        c.timingFunction = [CAMediaTimingFunction functionWithControlPoints:
                            0.16f :1.0f :0.3f :1.0f];
        item.win.animator.alphaValue = 1.0;
        [item.win.animator setFrame:final display:YES];
    } completionHandler:nil];
}

- (void)animate:(NSWindow *)win to:(NSRect)target duration:(NSTimeInterval)d {
    if (NSEqualRects(win.frame, target)) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = d;
        c.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [win.animator setFrame:target display:YES];
    } completionHandler:nil];
}

// Frames for every banner, in item order (oldest first).
//
// visibleFrame is read fresh on every pass, never cached: it accounts for the
// Dock and the menu bar, and it changes when the active display changes. He
// works across several displays, so a cached rect would strand the stack on the
// screen it was first laid out on.
- (NSArray<NSValue *> *)targetFrames {
    NSRect vis = [NSScreen mainScreen].visibleFrame;
    BOOL bottom = EnvB("AGENT_HUD_ANCHOR_BOTTOM", YES);
    NSMutableArray<NSValue *> *out = [NSMutableArray array];

    if (bottom) {
        // Newest at the bottom, older pushed upward, which is the direction a
        // bottom anchored stack is read in.
        CGFloat y = NSMinY(vis) + kMargin;
        NSMutableArray<NSValue *> *rev = [NSMutableArray array];
        for (HudItem *it in [self.items reverseObjectEnumerator]) {
            NSSize sz = it.win.frame.size;
            [rev addObject:[NSValue valueWithRect:
                NSMakeRect(NSMaxX(vis) - sz.width - kMargin, y, sz.width, sz.height)]];
            y += sz.height + kStackGap;
        }
        for (NSValue *v in [rev reverseObjectEnumerator]) [out addObject:v];
    } else {
        CGFloat y = NSMaxY(vis) - kMargin;
        for (HudItem *it in self.items) {
            NSSize sz = it.win.frame.size;
            [out addObject:[NSValue valueWithRect:
                NSMakeRect(NSMaxX(vis) - sz.width - kMargin, y - sz.height, sz.width, sz.height)]];
            y -= sz.height + kStackGap;
        }
    }
    return out;
}

- (void)remove:(HudItem *)item {
    if (![self.items containsObject:item]) return;
    [self.items removeObject:item];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.24;
        item.win.animator.alphaValue = 0;
    } completionHandler:^{
        [item.win orderOut:nil];
    }];
    [self renumber];
    // Survivors close the gap. Animated deliberately: these sit in peripheral
    // vision and windows teleporting reads as a glitch.
    [self relayoutAnimated:YES];
}

- (void)relayoutAnimated:(BOOL)animated {
    NSArray<NSValue *> *targets = [self targetFrames];
    if (targets.count != self.items.count) return;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSRect t = targets[i].rectValue;
        if (animated) {
            [self animate:self.items[i].win to:t duration:0.26];
        } else {
            [self.items[i].win setFrame:t display:YES];
        }
    }
}

// Focus the Nth banner counting from the BOTTOM, which under this anchor is
// the newest. n=1 with no argument is what the plain hotkey means.
//
// This lives in the daemon because the daemon is the only component that knows
// what is actually on screen. The previous hotkey asked agent-focus.sh, which
// reads .last, and .last records the last session to fire ANY hook: a warm
// SessionStart or an event with notifications suppressed both move it without
// ever showing a banner. Verified: firing `warm` moves .last and shows nothing.
// So the old hotkey could send you to a session with no banner while three real
// ones sat on screen.
- (void)focusIndex:(NSInteger)n {
    if (self.items.count == 0) {
        // Nothing on screen: fall back to the registry, which is what the
        // hotkey used to do unconditionally. Still the right answer here.
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/bin/bash";
        t.arguments = @[[NSHomeDirectory() stringByAppendingPathComponent:
                            @".claude/hooks/agent-focus.sh"], @"focus"];
        @try { [t launch]; } @catch (__unused NSException *ex) {}
        return;
    }
    if (n < 1) n = 1;
    if (n > (NSInteger)self.items.count) return;
    [self.items[self.items.count - n] activateClick];
}

// Numerals count from the bottom, matching the hotkeys and the reading order of
// a bottom anchored stack.
- (void)renumber {
    BOOL show = EnvB("AGENT_HUD_INDEX", YES) && self.items.count > 1;
    NSUInteger total = self.items.count;
    for (NSUInteger i = 0; i < total; i++) {
        [self.items[i] setIndex:(NSInteger)(total - i) visible:show];
    }
}

- (void)dismissAll {
    for (HudItem *it in [self.items copy]) [it dismiss];
}
@end

// ------------------------------------------------------------------ daemon

static NSString *Unescape(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"]
                stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
}

static void HandleLine(NSString *line) {
    if ([line isEqualToString:@"quit"]) {
        [gMgr dismissAll];
        // Give the fade time to finish before tearing the process down.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        return;
    }
    if ([line hasPrefix:@"focus"]) {
        NSArray<NSString *> *fp = [line componentsSeparatedByString:@"\t"];
        [gMgr focusIndex:fp.count > 1 ? fp[1].integerValue : 1];
        return;
    }
    NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
    if (f.count < 1 || f[0].length == 0) return;
    NSString *(^at)(NSUInteger) = ^(NSUInteger i) {
        return i < f.count ? Unescape(f[i]) : @"";
    };
    double secs = f.count > 5 ? f[5].doubleValue : 4.5;
    if (secs <= 0) secs = 4.5;
    NSString *ev = f.count > 6 ? Unescape(f[6]) : @"done";
    if (ev.length == 0) ev = @"done";
    NSString *pv = f.count > 7 ? Unescape(f[7]) : @"claude";
    if (pv.length == 0) pv = @"claude";
    HudItem *item = [[HudItem alloc] initWithTitle:at(0) subtitle:at(1) body:at(2)
                                             image:at(3) click:at(4) seconds:secs
                                             event:ev provider:pv];
    [gMgr add:item];
}

static int RunDaemon(void) {
    // Exactly one daemon, enforced atomically. Several banners firing at once
    // all find no daemon and all try to start one, so a pidfile check here
    // would still race: every loser would already have run mkfifo, which
    // unlinks and recreates the FIFO and orphans the winner's reader. flock is
    // the only check that cannot interleave. Losers exit silently and their
    // clients then find the winner through the pidfile.
    int lockfd = open(StatePath(@"hud.lock").UTF8String, O_CREAT | O_RDWR, 0600);
    if (lockfd < 0) return 1;
    if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) return 0;

    NSString *fifo = StatePath(@"hud.fifo");
    NSString *pidf = StatePath(@"hud.pid");
    unlink(fifo.UTF8String);
    if (mkfifo(fifo.UTF8String, 0600) != 0) return 1;
    int fd = open(fifo.UTF8String, O_RDWR);   // never EOFs, writers never block
    if (fd < 0) return 1;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gMgr = [[HudManager alloc] init];

    [[NSString stringWithFormat:@"%d\n", getpid()]
        writeToFile:pidf atomically:YES encoding:NSUTF8StringEncoding error:nil];

    static NSMutableData *pending;
    pending = [NSMutableData data];
    static dispatch_source_t rd;
    rd = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(rd, ^{
        char buf[8192];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) return;
        [pending appendBytes:buf length:(NSUInteger)n];
        const char *b = pending.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < pending.length; i++) {
            if (b[i] != '\n') continue;
            @autoreleasepool {
                NSString *line = [[NSString alloc] initWithBytes:b + start
                                                          length:i - start
                                                        encoding:NSUTF8StringEncoding];
                start = i + 1;
                if (line.length) HandleLine(line);
            }
        }
        if (start > 0) [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    });
    dispatch_resume(rd);

    // The Hammerspoon dismiss hotkey reaches us as SIGUSR1, deliberately not
    // SIGTERM. Trapping SIGTERM to mean "dismiss" made the daemon unkillable by
    // ordinary means: pkill stopped working and stale daemons piled up across
    // restarts. SIGTERM keeps its normal meaning; SIGUSR1 clears the banners.
    signal(SIGUSR1, SIG_IGN);
    static dispatch_source_t sig;
    sig = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0,
                                 dispatch_get_main_queue());
    dispatch_source_set_event_handler(sig, ^{ [gMgr dismissAll]; });
    dispatch_resume(sig);

    [NSApp run];
    return 0;
}

// ------------------------------------------------------------------ client

static BOOL DaemonAlive(void) {
    NSString *pidf = StatePath(@"hud.pid");
    NSString *s = [NSString stringWithContentsOfFile:pidf
                                            encoding:NSUTF8StringEncoding error:nil];
    int pid = s.intValue;
    return pid > 0 && kill(pid, 0) == 0;
}

static NSString *Escape(NSString *s) {
    return [[(s ?: @"") stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"]
                        stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--daemon") == 0) return RunDaemon();

        if (argc >= 2 && strcmp(argv[1], "--focus") == 0) {
            // Exit non-zero when there is no daemon, so the hotkey can fall
            // back to the registry lookup.
            if (!DaemonAlive()) return 1;
            FILE *f = fopen(StatePath(@"hud.fifo").UTF8String, "w");
            if (!f) return 1;
            if (argc >= 3) fprintf(f, "focus\t%s\n", argv[2]);
            else           fputs("focus\n", f);
            fclose(f);
            return 0;
        }

        if (argc >= 2 && strcmp(argv[1], "--stop") == 0) {
            FILE *f = fopen(StatePath(@"hud.fifo").UTF8String, "w");
            if (f) { fputs("quit\n", f); fclose(f); }
            return 0;   // "quit" fades the banners, then the daemon exits
        }

        if (argc < 2) {
            fprintf(stderr, "usage: agenthud <title> [subtitle] [body] [image] [click] [secs] [event] [provider]\n"
                            "       agenthud --daemon | --stop\n");
            return 2;
        }

        NSMutableArray *parts = [NSMutableArray array];
        for (int i = 1; i <= 8; i++) {
            [parts addObject:Escape(i < argc ? @(argv[i]) : @"")];
        }
        NSString *line = [[parts componentsJoinedByString:@"\t"] stringByAppendingString:@"\n"];

        // Start the owner on demand, then hand the banner over. Two banners
        // racing here is fine: both writes land on the same FIFO and the daemon
        // serialises them, which is the whole point of having one owner.
        for (int attempt = 0; attempt < 2; attempt++) {
            if (DaemonAlive()) {
                FILE *f = fopen(StatePath(@"hud.fifo").UTF8String, "w");
                if (f) {
                    fputs(line.UTF8String, f);
                    fclose(f);
                    return 0;
                }
            }
            if (attempt == 0) {
                NSTask *t = [[NSTask alloc] init];
                t.launchPath = [NSBundle mainBundle].executablePath
                               ?: @(argv[0]);
                t.arguments = @[@"--daemon"];
                @try { [t launch]; } @catch (__unused NSException *ex) { break; }
                // A cold daemon has to take the lock, make the FIFO and bring
                // up AppKit before it writes its pidfile. Two seconds was not
                // enough on a loaded machine: the client gave up, exited 0, and
                // the banner was silently dropped even though the daemon came
                // up a moment later. Six seconds, still polled every 50ms so a
                // warm start stays instant.
                for (int i = 0; i < 120 && !DaemonAlive(); i++) usleep(50000);
            }
        }
        fprintf(stderr, "agenthud: could not reach the daemon\n");
        return 1;
    }
}
