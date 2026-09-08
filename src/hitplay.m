// hitplay: a low latency one shot player for the agent notification hits.
//
// Why this exists. `afplay` costs a fixed ~800 ms per invocation on this
// machine no matter how short the file is, because it cold starts CoreAudio
// every time. `ffplay` is ~350 ms. Neither can land a hit on a beat.
//
// So this runs as a small daemon that keeps an AVAudioEngine running (the
// device stays warm) with every wav preloaded into memory. Triggering a sound
// is then a single write of a path into a FIFO, which from the shell is one
// `printf` and no process spawn at all.
//
//   hitplay --daemon [dir]   preload dir, hold the device open, read the FIFO
//   hitplay --stop           ask a running daemon to exit
//   hitplay <file> [gain]    one shot, no daemon (fallback and for testing)
//
// FIFO protocol: one request per line, "<path>" or "<path>\t<gain>".
//
// Build: see build.sh next to this file.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/file.h>

static const int kVoices = 4;              // simultaneous overlapping hits
static const double kDefaultIdleExit = 3600.0;  // release the device after 1h

static AVAudioFormat *gFormat = nil;       // canonical engine format
static NSMutableDictionary<NSString *, AVAudioPCMBuffer *> *gCache = nil;

// Load a wav and convert it into the engine's canonical format, so that files
// with a different sample rate or channel count still work.
static AVAudioPCMBuffer *LoadBuffer(NSString *path) {
    AVAudioPCMBuffer *hit = gCache[path];
    if (hit) return hit;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                                      error:&err];
    if (!file || err) return nil;

    AVAudioFormat *src = file.processingFormat;
    AVAudioFrameCount frames = (AVAudioFrameCount)file.length;
    if (frames == 0) return nil;

    AVAudioPCMBuffer *raw = [[AVAudioPCMBuffer alloc] initWithPCMFormat:src
                                                          frameCapacity:frames];
    if (![file readIntoBuffer:raw error:&err] || err) return nil;

    AVAudioPCMBuffer *out = raw;
    if (![src isEqual:gFormat]) {
        AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:src toFormat:gFormat];
        if (!conv) return nil;
        double ratio = gFormat.sampleRate / src.sampleRate;
        AVAudioFrameCount cap = (AVAudioFrameCount)(frames * ratio) + 4096;
        out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:gFormat frameCapacity:cap];
        __block BOOL fed = NO;
        AVAudioConverterOutputStatus st = [conv convertToBuffer:out error:&err
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *s) {
                if (fed) { *s = AVAudioConverterInputStatus_EndOfStream; return nil; }
                fed = YES;
                *s = AVAudioConverterInputStatus_HaveData;
                return raw;
            }];
        if (st == AVAudioConverterOutputStatus_Error) return nil;
    }

    if (path) gCache[path] = out;
    return out;
}

static int RunOneShot(NSString *path, float gain) {
    @autoreleasepool {
        AVAudioEngine *engine = [[AVAudioEngine alloc] init];
        AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
        gFormat = [engine.mainMixerNode outputFormatForBus:0];
        gCache = [NSMutableDictionary dictionary];

        AVAudioPCMBuffer *buf = LoadBuffer(path);
        if (!buf) { fprintf(stderr, "hitplay: cannot load %s\n", path.UTF8String); return 1; }

        [engine attachNode:node];
        [engine connect:node to:engine.mainMixerNode format:buf.format];
        node.volume = gain;

        NSError *err = nil;
        if (![engine startAndReturnError:&err]) {
            fprintf(stderr, "hitplay: engine failed: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [node scheduleBuffer:buf completionHandler:^{ dispatch_semaphore_signal(done); }];
        [node play];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        // Let the tail flush out of the device before tearing the engine down.
        usleep(60000);
        [engine stop];
    }
    return 0;
}

// AVAudioEngine pins itself to whatever the default output device was when it
// started. Switch headphones, dock, or a virtual device like Teams audio, and
// the engine keeps rendering into the old one: the process looks healthy and
// you simply hear nothing. Nothing tells us this happened, so the engine is
// re-validated before every hit and while idle, and rebuilt when it has gone
// stale. This is the difference between a daemon that works all day and one
// that silently dies the first time you unplug something.
static BOOL EnsureEngine(AVAudioEngine *engine,
                         NSArray<AVAudioPlayerNode *> *voices,
                         NSString *dir) {
    AVAudioFormat *now = [engine.mainMixerNode outputFormatForBus:0];
    BOOL formatChanged = (gFormat && now && ![now isEqual:gFormat]);
    if (engine.isRunning && !formatChanged) return YES;

    [engine stop];
    gFormat = [engine.mainMixerNode outputFormatForBus:0];
    if (formatChanged) {
        // Buffers were decoded into the old device's format, so they cannot be
        // scheduled on the new graph. Drop them and let them reload on demand.
        [gCache removeAllObjects];
    }
    for (AVAudioPlayerNode *n in voices) {
        [engine disconnectNodeOutput:n];
        [engine connect:n to:engine.mainMixerNode format:gFormat];
    }
    NSError *err = nil;
    if (![engine startAndReturnError:&err]) {
        fprintf(stderr, "hitplay: restart failed: %s\n",
                err.localizedDescription.UTF8String);
        return NO;
    }
    for (AVAudioPlayerNode *n in voices) [n play];
    if (formatChanged && dir) {
        NSArray<NSString *> *files =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f.pathExtension.lowercaseString isEqualToString:@"wav"]) {
                LoadBuffer([dir stringByAppendingPathComponent:f]);
            }
        }
    }
    return YES;
}

static volatile sig_atomic_t gStop = 0;
static void OnSignal(int s) { (void)s; gStop = 1; }

static int RunDaemon(NSString *dir, NSString *stateDir) {
    @autoreleasepool {
        // Exactly one daemon. A pidfile check alone races: several hooks firing
        // together all see a stale or missing pidfile and all spawn a daemon,
        // and each extra one holds the audio device open for nothing. Seven of
        // them accumulated before this was added.
        [[NSFileManager defaultManager] createDirectoryAtPath:stateDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        NSString *lockPath = [stateDir stringByAppendingPathComponent:@"hitplay.lock"];
        int lockfd = open(lockPath.UTF8String, O_CREAT | O_RDWR, 0600);
        if (lockfd < 0) return 1;
        if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) return 0;
        NSString *fifo = [stateDir stringByAppendingPathComponent:@"hit.fifo"];
        NSString *pidf = [stateDir stringByAppendingPathComponent:@"hitplay.pid"];

        [[NSFileManager defaultManager] createDirectoryAtPath:stateDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        unlink(fifo.UTF8String);
        if (mkfifo(fifo.UTF8String, 0600) != 0) {
            fprintf(stderr, "hitplay: mkfifo failed\n");
            return 1;
        }

        // O_RDWR so the FIFO never reports EOF when a writer closes, which
        // keeps the read loop simple and means a writer never blocks.
        int fd = open(fifo.UTF8String, O_RDWR);
        if (fd < 0) { fprintf(stderr, "hitplay: cannot open fifo\n"); return 1; }

        AVAudioEngine *engine = [[AVAudioEngine alloc] init];
        gFormat = [engine.mainMixerNode outputFormatForBus:0];
        gCache = [NSMutableDictionary dictionary];

        NSMutableArray<AVAudioPlayerNode *> *voices = [NSMutableArray array];
        for (int i = 0; i < kVoices; i++) {
            AVAudioPlayerNode *n = [[AVAudioPlayerNode alloc] init];
            [engine attachNode:n];
            [engine connect:n to:engine.mainMixerNode format:gFormat];
            [voices addObject:n];
        }

        // Preload everything up front so the first real hit is not the slow one.
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f.pathExtension.lowercaseString isEqualToString:@"wav"]) {
                LoadBuffer([dir stringByAppendingPathComponent:f]);
            }
        }

        NSError *err = nil;
        if (![engine startAndReturnError:&err]) {
            fprintf(stderr, "hitplay: engine failed: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        for (AVAudioPlayerNode *n in voices) [n play];

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:pidf atomically:YES
                                                         encoding:NSUTF8StringEncoding error:nil];
        signal(SIGTERM, OnSignal);
        signal(SIGINT, OnSignal);
        signal(SIGPIPE, SIG_IGN);

        double idleExit = kDefaultIdleExit;
        const char *ie = getenv("AGENT_SOUND_DAEMON_IDLE");
        if (ie) idleExit = atof(ie);

        NSMutableData *pending = [NSMutableData data];
        char chunk[4096];
        int voice = 0;
        NSDate *lastHit = [NSDate date];

        while (!gStop) {
            fd_set rd;
            FD_ZERO(&rd);
            FD_SET(fd, &rd);
            struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
            int r = select(fd + 1, &rd, NULL, NULL, &tv);
            if (r < 0) { if (errno == EINTR) continue; break; }

            if (r == 0) {
                EnsureEngine(engine, voices, dir);
                if (idleExit > 0 && -[lastHit timeIntervalSinceNow] > idleExit) break;
                continue;
            }

            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) continue;
            [pending appendBytes:chunk length:(NSUInteger)n];

            // Split the buffer on newlines, keeping any partial trailing line.
            const char *bytes = pending.bytes;
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < pending.length; i++) {
                if (bytes[i] != '\n') continue;
                @autoreleasepool {
                    NSString *line = [[NSString alloc] initWithBytes:bytes + start
                                                              length:i - start
                                                            encoding:NSUTF8StringEncoding];
                    start = i + 1;
                    line = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                    if (line.length == 0) continue;   // stray newline, ignore
                    if ([line isEqualToString:@"quit"]) { gStop = 1; break; }

                    float gain = 1.0f;
                    NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
                    NSString *path = parts[0];
                    if (parts.count > 1) gain = parts[1].floatValue;

                    EnsureEngine(engine, voices, dir);
                    AVAudioPCMBuffer *buf = LoadBuffer(path);
                    if (!buf) continue;
                    AVAudioPlayerNode *n2 = voices[voice % kVoices];
                    voice++;
                    n2.volume = gain;
                    [n2 scheduleBuffer:buf atTime:nil
                               options:AVAudioPlayerNodeBufferInterrupts
                     completionHandler:nil];
                    lastHit = [NSDate date];
                }
            }
            if (start > 0) {
                [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            }
        }

        [engine stop];
        close(fd);
        unlink(fifo.UTF8String);
        unlink(pidf.UTF8String);
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *stateDir = [NSString stringWithFormat:@"%s/agent-sound",
                              getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp"];
        stateDir = [stateDir stringByReplacingOccurrencesOfString:@"//" withString:@"/"];

        if (argc >= 2 && strcmp(argv[1], "--daemon") == 0) {
            NSString *dir = (argc >= 3)
                ? [NSString stringWithUTF8String:argv[2]]
                : [home stringByAppendingPathComponent:@".claude/sounds"];
            return RunDaemon(dir, stateDir);
        }

        if (argc >= 2 && strcmp(argv[1], "--stop") == 0) {
            NSString *fifo = [stateDir stringByAppendingPathComponent:@"hit.fifo"];
            FILE *f = fopen(fifo.UTF8String, "w");
            if (f) { fputs("quit\n", f); fclose(f); }
            return 0;
        }

        if (argc < 2) {
            fprintf(stderr, "usage: hitplay --daemon [dir] | --stop | <file.wav> [gain]\n");
            return 2;
        }

        float gain = (argc >= 3) ? atof(argv[2]) : 1.0f;
        return RunOneShot([NSString stringWithUTF8String:argv[1]], gain);
    }
}
