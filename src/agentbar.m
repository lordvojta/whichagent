// agentbar: a menu bar item answering "how many agents need me" without being asked.
//
// This is the point of the whole state-tracking exercise. A banner interrupts
// you once and is gone; a count sitting in the menu bar is a standing answer.
// The badge deliberately counts only sessions that BLOCK progress, not every
// idle one: with thirty sessions a total would read as wallpaper.
//
// The count is computed natively by reading the state directory, because it
// runs on a timer forever. The menu shells out to `whichagent json`, because it
// only runs when you actually open it and there is no reason to duplicate the
// join and sort logic for a cold path.
//
//   agentbar        run in the foreground (launchd or `&`)

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

// Show the age alongside the count only once it is interesting.
static const NSTimeInterval kAgeThreshold = 300;   // 5 minutes

static NSString *StateDir(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"AGENT_STATE_DIR"];
    if (env.length) return env;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/cache/agent-state"];
}

static NSString *ToolPath(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"WHICHAGENT_BIN"];
    if (env.length) return env;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/hooks/whichagent"];
}

// Only these mean the agent cannot proceed. "finished" is a waiting session
// too, but it is not stopping you. Kept in sync with BLOCKING in whichagent.
static BOOL ReasonBlocks(NSString *r) {
    return [r isEqualToString:@"plan"]
        || [r isEqualToString:@"permission"]
        || [r isEqualToString:@"idle"];
}

@interface Bar : NSObject <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *item;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray *rows;
- (void)openMenu;
@end

static Bar *gBar = nil;

// Carbon rather than a Hammerspoon binding, for two reasons: it keeps the
// hotkey in the same process as the thing it opens, so there is no second file
// to install and keep in sync, and RegisterEventHotKey takes a VIRTUAL KEYCODE,
// which is a physical key position. Binding by character would land on whatever
// the active layout produces there, which on a Czech layout is not the letter
// you typed.
static OSStatus HotKeyFired(EventHandlerCallRef ref, EventRef evt, void *ctx) {
    (void)ref; (void)evt; (void)ctx;
    [gBar openMenu];
    return noErr;
}

static void InstallHotKey(void) {
    // cmd+ctrl+W. Option is deliberately avoided: on British and Czech layouts
    // it is a dead-key modifier. cmd+ctrl matches the other bindings here.
    EventHotKeyID hkid = { .signature = 'wagt', .id = 1 };
    EventTypeSpec spec = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
    InstallApplicationEventHandler(&HotKeyFired, 1, &spec, NULL, NULL);
    EventHotKeyRef ref;
    RegisterEventHotKey(kVK_ANSI_W, cmdKey | controlKey, hkid, GetApplicationEventTarget(), 0, &ref);
}

@implementation Bar

- (instancetype)init {
    if (!(self = [super init])) return nil;

    self.item = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;                 // rebuilt on open, never on a timer
    self.item.menu = menu;

    gBar = self;
    InstallHotKey();

    [self refresh];
    // 4s is under the threshold where a stale badge feels wrong, and the work
    // is a directory listing, not a process launch.
    self.timer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) { (void)t; [self refresh]; }];
    return self;
}

/** Count blocking sessions, and how long the most neglected has waited.
 *
 * Read natively rather than by shelling out to the CLI, because this runs on a
 * timer for the life of the login session and a python launch every few seconds
 * is a poor trade for logic this small.
 */
- (void)scanCount:(NSInteger *)outCount oldest:(NSTimeInterval *)outOldest {
    NSString *dir = StateDir();
    NSArray<NSString *> *names =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSInteger n = 0;
    NSTimeInterval oldest = 0, now = NSDate.date.timeIntervalSince1970;

    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *body = [NSString stringWithContentsOfFile:
                              [dir stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (!body) continue;

        NSString *state = nil, *reason = nil;
        NSTimeInterval since = now;
        for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:eq.location];
            NSString *v = [line substringFromIndex:eq.location + 1];
            if ([k isEqualToString:@"STATE"])  state = v;
            if ([k isEqualToString:@"REASON"]) reason = v;
            if ([k isEqualToString:@"SINCE"])  since = v.doubleValue;
        }
        if ([state isEqualToString:@"waiting"] && reason && ReasonBlocks(reason)) {
            n++;
            oldest = MAX(oldest, now - since);
        }
    }
    if (outCount)  *outCount = n;
    if (outOldest) *outOldest = oldest;
}

static NSString *ShortAge(NSTimeInterval s) {
    if (s < 60)   return [NSString stringWithFormat:@"%.0fs", s];
    if (s < 3600) return [NSString stringWithFormat:@"%.0fm", s / 60];
    return [NSString stringWithFormat:@"%.0fh", s / 3600];
}

- (void)refresh {
    NSInteger n = 0;
    NSTimeInterval oldest = 0;
    [self scanCount:&n oldest:&oldest];

    NSStatusBarButton *b = self.item.button;

    // Filled and titled when something wants you; hollow and untitled when
    // nothing does. The resting state has to be quiet or it stops being a
    // signal and becomes another thing in the menu bar.
    NSString *symbol = n > 0 ? @"hand.raised.fill" : @"hand.raised";
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                             accessibilityDescription:@"agents waiting"];
    if (!img) img = [NSImage imageNamed:NSImageNameStatusAvailable];  // pre-SF-Symbols fallback
    img.template = YES;
    b.image = img;
    b.imagePosition = n > 0 ? NSImageLeft : NSImageOnly;
    b.alphaValue = n > 0 ? 1.0 : 0.55;

    // Past a few minutes the count alone stops being the useful number. Two
    // agents waiting is routine; one waiting twenty minutes is something you
    // have forgotten. Showing the age only once it is interesting keeps the
    // resting badge to a single digit.
    if (n > 0 && oldest >= kAgeThreshold) {
        b.title = [NSString stringWithFormat:@" %ld · %@", (long)n, ShortAge(oldest)];
    } else if (n > 0) {
        b.title = [NSString stringWithFormat:@" %ld", (long)n];
    } else {
        b.title = @"";
    }

    b.toolTip = n > 0
        ? [NSString stringWithFormat:@"%ld agent%@ waiting on you, longest %@",
             (long)n, n == 1 ? @"" : @"s", ShortAge(oldest)]
        : @"no agents waiting";
}

/** Ask the CLI for the full picture. Cold path, so correctness over speed. */
- (NSArray *)load {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    t.arguments = @[@"python3", ToolPath(), @"json"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) return @[];
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [j isKindOfClass:NSArray.class] ? j : @[];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    self.rows = [self load];

    if (self.rows.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No agent sessions"
                                                       action:NULL keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
    }

    NSInteger i = 0;
    BOOL dividedAfterBlocking = NO;
    for (NSDictionary *r in self.rows) {
        BOOL blocking = [r[@"blocking"] boolValue];
        if (!blocking && !dividedAfterBlocking && i > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
            dividedAfterBlocking = YES;
        }

        NSString *state = r[@"state"], *reason = r[@"reason"];
        NSString *what = [state isEqualToString:@"working"] ? @"working"
                       : [reason isEqualToString:@"permission"] ? @"needs permission"
                       : [reason isEqualToString:@"plan"]       ? @"plan ready"
                       : [reason isEqualToString:@"idle"]       ? @"waiting on you"
                                                                : @"finished";
        double since = [r[@"since"] doubleValue];
        NSString *age = since < 60  ? [NSString stringWithFormat:@"%.0fs", since]
                      : since < 3600 ? [NSString stringWithFormat:@"%.0fm", since / 60]
                                     : [NSString stringWithFormat:@"%.0fh", since / 3600];

        NSString *title = [state isEqualToString:@"working"]
            ? [NSString stringWithFormat:@"%@  %@", r[@"project"], what]
            : [NSString stringWithFormat:@"%@  %@  %@", r[@"project"], what, age];

        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(jump:)
                                             keyEquivalent:(i < 9 ? [@(i + 1) stringValue] : @"")];
        mi.keyEquivalentModifierMask = 0;   // bare 1-9 while the menu is open
        mi.target = self;
        mi.tag = i;
        mi.state = blocking ? NSControlStateValueOn : NSControlStateValueOff;
        if (!blocking) mi.attributedTitle =
            [[NSAttributedString alloc] initWithString:title attributes:@{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
        [menu addItem:mi];
        i++;
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit whichagent"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
}

/** Pop the menu open from the keyboard, as though it had been clicked. */
- (void)openMenu {
    [self.item.button performClick:nil];
}

- (void)jump:(NSMenuItem *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.rows.count) return;
    NSString *sid = self.rows[sender.tag][@"sid"];
    if (!sid.length) return;

    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[[NSHomeDirectory() stringByAppendingPathComponent:@".claude/hooks/agent-focus.sh"],
                    @"focus", sid];
    [t launchAndReturnError:nil];
}

@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Accessory: a menu bar item with no Dock tile and no menu bar of its own.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Bar *bar = [[Bar alloc] init];
        (void)bar;
        [NSApp run];
    }
    return 0;
}
