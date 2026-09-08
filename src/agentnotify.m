// agentnotify: post a macOS notification banner for a coding-agent event.
//
// This has to live inside a .app bundle. UNUserNotificationCenter refuses to do
// anything from a process without a bundle identifier, which is also why the
// obvious `osascript -e 'display notification'` route posts everything under
// the name "Script Editor": you are borrowing that app's bundle. Running from
// our own bundle means the banner is branded, can carry a subtitle, and can
// group by repo with a thread identifier.
//
//   agentnotify <title> [subtitle] [body] [thread-id] [image.png]
//   agentnotify --check     print authorization status, then exit
//
// Exit codes: 0 posted, 2 usage, 3 not authorized, 4 delivery failed. The shell
// wrapper uses these to decide whether to fall back to osascript.

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

// Every run appends one line to ~/.claude/agent-notify.log. When this is
// launched through `open` there is no stdout to capture, so a log file is the
// only way to find out why a banner did not appear.
static void LogLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [NSHomeDirectory()
        stringByAppendingPathComponent:@".claude/agent-notify.log"];
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static const char *AuthName(UNAuthorizationStatus s) {
    switch (s) {
        case UNAuthorizationStatusNotDetermined: return "notDetermined";
        case UNAuthorizationStatusDenied:        return "denied";
        case UNAuthorizationStatusAuthorized:    return "authorized";
        case UNAuthorizationStatusProvisional:   return "provisional";
        default:                                 return "unknown";
    }
}

static UNAuthorizationStatus CurrentStatus(UNUserNotificationCenter *center) {
    __block UNAuthorizationStatus status = UNAuthorizationStatusNotDetermined;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        status = s.authorizationStatus;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: agentnotify <title> [subtitle] [body] [thread-id]\n"
                            "       agentnotify --check\n");
            return 2;
        }

        // UserNotifications needs a running NSApplication on macOS.
        [NSApplication sharedApplication];
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

        if (strcmp(argv[1], "--check") == 0) {
            printf("%s\n", AuthName(CurrentStatus(center)));
            return 0;
        }

        LogLine(@"run: title=%s status=%s bundle=%@", argv[1],
                AuthName(CurrentStatus(center)),
                [[NSBundle mainBundle] bundleIdentifier]);

        // Asking every time is cheap once granted, and it is what triggers the
        // one time system prompt on first use.
        __block BOOL granted = NO;
        dispatch_semaphore_t authSem = dispatch_semaphore_create(0);
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                              completionHandler:^(BOOL ok, NSError *err) {
            granted = ok;
            if (err) fprintf(stderr, "agentnotify: auth error: %s\n",
                             err.localizedDescription.UTF8String);
            dispatch_semaphore_signal(authSem);
        }];
        dispatch_semaphore_wait(authSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        if (!granted) {
            fprintf(stderr, "agentnotify: not authorized (%s)\n",
                    AuthName(CurrentStatus(center)));
            LogLine(@"DENIED: status=%s", AuthName(CurrentStatus(center)));
            return 3;
        }

        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @(argv[1]);
        if (argc > 2 && strlen(argv[2])) content.subtitle = @(argv[2]);
        if (argc > 3 && strlen(argv[3])) content.body = @(argv[3]);
        // Group by repo so a busy project collapses into one stack.
        content.threadIdentifier = (argc > 4 && strlen(argv[4])) ? @(argv[4]) : @"agent";

        // Project artwork. UNNotificationAttachment takes ownership of the file
        // it is given and moves it into the notification store, so it gets a
        // throwaway copy rather than the cached icon itself.
        if (argc > 5 && strlen(argv[5])) {
            NSString *src = @(argv[5]);
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"agenticon-%@.png", [[NSUUID UUID] UUIDString]]];
            NSError *copyErr = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:tmp error:&copyErr]) {
                NSError *attErr = nil;
                UNNotificationAttachment *att =
                    [UNNotificationAttachment attachmentWithIdentifier:@"icon"
                                                                   URL:[NSURL fileURLWithPath:tmp]
                                                               options:nil
                                                                 error:&attErr];
                if (att) {
                    content.attachments = @[att];
                } else {
                    fprintf(stderr, "agentnotify: attach failed: %s\n",
                            attErr.localizedDescription.UTF8String);
                }
            } else {
                fprintf(stderr, "agentnotify: could not copy image: %s\n",
                        copyErr.localizedDescription.UTF8String);
            }
        }
        // Deliberately silent: we already play our own hit, and the system
        // sound would land on top of it.
        content.sound = nil;

        UNNotificationRequest *req =
            [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                 content:content
                                                 trigger:nil];

        __block NSError *addErr = nil;
        dispatch_semaphore_t addSem = dispatch_semaphore_create(0);
        [center addNotificationRequest:req withCompletionHandler:^(NSError *err) {
            addErr = err;
            dispatch_semaphore_signal(addSem);
        }];
        dispatch_semaphore_wait(addSem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (addErr) {
            fprintf(stderr, "agentnotify: delivery failed: %s\n",
                    addErr.localizedDescription.UTF8String);
            LogLine(@"FAILED: %@", addErr.localizedDescription);
            return 4;
        }
        LogLine(@"POSTED ok");
        return 0;
    }
}
