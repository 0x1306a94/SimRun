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
// `screenSize` (points) and `cornerRadius` are the simulated device's screen; the window follows the size of the frames
// the app presents.
- (instancetype)initWithTitle:(NSString *)title screenSize:(NSSize)screenSize cornerRadius:(CGFloat)cornerRadius;
// Spawns `argv[0]` with `env`, bootstrap port `bootstrap` (a simns namespace), stdio `fds` (-1 = inherit), working dir `cwd`.
- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error;
- (void)terminate;   // end the app (window closed / client went away / Quit App)
- (void)bringToFront;
// Collect the app's stdout/stderr from `fd` (read end of a pipe; the session owns it) into the log window and
// ~/Library/Logs/SimRun/<title>.log. Used for apps launched from the launcher (no terminal).
- (void)captureOutputFrom:(int)fd;
- (void)showLog;
// The app's screen as it last presented it, as PNG at its pixel size; nil before its first frame.
- (NSData *)screenshotPNG;
// Runs a JavaScript `source` in the app (script.dylib). `output` is called on a background queue with each console
// line ("log"), then once more with the outcome: "result" (the script's value, possibly empty), "exception" (it threw)
// or "error" (the app went away first). NO if the app can't run scripts: it isn't running, it hasn't started its
// script channel yet, or it was launched with SCRIPT_DISABLE.
- (BOOL)runScript:(NSString *)source output:(void (^)(NSString *key, NSString *text))output;
@end
