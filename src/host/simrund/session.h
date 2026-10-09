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

// Creates the window and the session port (what the app finds in mach_ports_lookup()[0]: frames + its input port).
- (instancetype)initWithTitle:(NSString *)title;
// Spawns `argv[0]` with `env`, bootstrap port `bootstrap` (a simns namespace), stdio `fds` (-1 = inherit), working dir `cwd`.
- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error;
- (void)terminate;   // SIGTERM the app (window closed / client went away)
@end
