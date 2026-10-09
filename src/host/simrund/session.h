// session.h — one running sim app inside simrund: its window, framebuffer surfaces, input port and process.
#pragma once
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

@class SRSession;
typedef void (^SRSessionExitHandler)(SRSession *session, int waitStatus);

@interface SRSession : NSObject <NSWindowDelegate>
@property (readonly) pid_t pid;
@property (readonly) NSString *title;
@property (copy) SRSessionExitHandler onExit;
// The window stays hidden until the app presents its first frame (no blank window while it launches); then it is
// placed, shown, `ready` becomes YES and onReady runs.
@property (readonly, getter=isReady) BOOL ready;
@property (copy) void (^onReady)(SRSession *session);
@property (copy) NSString *appPath;           // the .app this session runs (nil for bare binaries)
@property (readonly) NSWindow *window;

// Creates the window and the session port (what the app finds in mach_ports_lookup()[0]: frames + its input port).
- (instancetype)initWithTitle:(NSString *)title;
// Spawns `argv[0]` with `env`, bootstrap port `bootstrap` (a simns namespace), stdio `fds` (-1 = inherit), working dir `cwd`.
- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error;
- (void)terminate;   // end the app (window closed / client went away / Quit App)
- (void)bringToFront;
// Collect the app's stdout/stderr from `fd` (read end of a pipe; the session owns it) into the log window and
// ~/Library/Logs/SimRun/<title>.log. Used for apps launched from the launcher (no terminal).
- (void)captureOutputFrom:(int)fd;
- (void)showLog;
@end
