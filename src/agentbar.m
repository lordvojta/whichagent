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
@end

@implementation Bar

- (instancetype)init {
    if (!(self = [super init])) return nil;

    self.item = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;                 // rebuilt on open, never on a timer
    self.item.menu = menu;

    [self refresh];
    // 4s is under the threshold where a stale badge feels wrong, and the work
    // is a directory listing, not a process launch.
    self.timer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) { (void)t; [self refresh]; }];
    return self;
}

/** Count blocking sessions by reading the state files directly. */
- (NSInteger)blockingCount {
    NSString *dir = StateDir();
    NSArray<NSString *> *names =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSInteger n = 0;

    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *body = [NSString stringWithContentsOfFile:
                              [dir stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (!body) continue;

        NSString *state = nil, *reason = nil;
        for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:eq.location];
            NSString *v = [line substringFromIndex:eq.location + 1];
            if ([k isEqualToString:@"STATE"])  state = v;
            if ([k isEqualToString:@"REASON"]) reason = v;
        }
        if ([state isEqualToString:@"waiting"] && reason && ReasonBlocks(reason)) n++;
    }
    return n;
}

- (void)refresh {
    NSInteger n = [self blockingCount];
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
    b.title = n > 0 ? [NSString stringWithFormat:@" %ld", (long)n] : @"";
    b.alphaValue = n > 0 ? 1.0 : 0.55;
    b.toolTip = n > 0
        ? [NSString stringWithFormat:@"%ld agent%@ waiting on you", (long)n, n == 1 ? @"" : @"s"]
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
