// simrund — the shared SimRun host process (macOS, AppKit).
//
// One long-lived process owns every app window, one set of host-side "sim2host" services (IOSurface, Metal) and one
// `simns --serve` (the launchd_sim stand-in, which also runs the shared sim daemons). Apps are launched on request:
// each gets a private simns namespace layered over the global one, a window (SRSession), and the requesting client's
// stdio. Compared with one viewer + simns per app this saves their startup (~0.4 s) on every launch.
//
//   simrund --serve              serve requests from `simapp` clients on the Unix socket (see simrund_proto.h);
//                                exits after SIMRUND_IDLE seconds (default 600, 0 = never) without apps
//   simrund --run <exe> [args]   standalone: launch one app with this process's environment/stdio, exit with its status
//
// Must run with the simrun.sh environment (DYLD_ROOT_PATH etc.), which it passes on to simns and the apps.
#import <Cocoa/Cocoa.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/file.h>
#include "session.h"
#include "simns_proto.h"
#include "simrund_proto.h"
#include "gpuhost.h"

extern char **environ;

static void LOG(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
  fprintf(stderr, "[simrund] %s\n", s.UTF8String);
}
static NSString *ExecutableDir(void) {
  char buf[PATH_MAX]; uint32_t n = sizeof buf; _NSGetExecutablePath(buf, &n);
  char real[PATH_MAX]; realpath(buf, real);
  return [@(real) stringByDeletingLastPathComponent];
}

// A pending/active launch request.
@interface SRRequest : NSObject
@property NSArray<NSString *> *argv, *env; @property NSString *cwd, *title;
@property int sock; @property int fd0, fd1, fd2;   // client connection (-1 in --run mode) and its stdio
@property SRSession *session; @property dispatch_source_t eofSource;
@end
@implementation SRRequest @end

@interface SRServer : NSObject <NSApplicationDelegate>
@end

@implementation SRServer {
  BOOL _runMode; NSArray<NSString *> *_runArgv;
  mach_port_t _ctlPort;          // our receive port: simns sends SIMNS_MSG_HELLO here
  mach_port_t _nsCtl;            // simns control port (send right)
  pid_t _simnsPid;
  dispatch_source_t _ctlSource, _listenSource, _sigSource;
  int _listenFd; NSString *_socketPath;
  NSMutableArray<SRRequest *> *_pending, *_active;
  NSTimer *_idleTimer;
}

- (instancetype)initRunMode:(BOOL)run argv:(NSArray<NSString *> *)argv {
  if ((self = [super init])) { _runMode = run; _runArgv = argv; _pending = [NSMutableArray array]; _active = [NSMutableArray array]; _listenFd = -1; }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  signal(SIGTERM, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  _sigSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_sigSource, ^{ [NSApp terminate:nil]; });
  dispatch_resume(_sigSource);
  if (![self startSimns]) { LOG(@"cannot start simns"); exit(1); }
  if (_runMode) {
    SRRequest *r = [SRRequest new];
    r.argv = _runArgv; r.sock = -1; r.fd0 = r.fd1 = r.fd2 = -1;
    NSMutableArray *env = [NSMutableArray array]; for (char **e = environ; *e; e++) [env addObject:@(*e)];
    r.env = env; r.cwd = NSFileManager.defaultManager.currentDirectoryPath;
    r.title = NSProcessInfo.processInfo.environment[@"SIMRUN_TITLE"] ?: _runArgv.firstObject.lastPathComponent;
    [self enqueue:r];
  } else if (![self startListening]) exit(0);   // another server already owns the socket
  [self scheduleIdleCheck];
}

// ---------------------------------------------------------------- simns (shared namespace + daemons)
- (BOOL)startSimns {
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_ctlPort);
  mach_port_insert_right(mach_task_self(), _ctlPort, _ctlPort, MACH_MSG_TYPE_MAKE_SEND);
  _ctlSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _ctlPort, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_ctlSource, ^{ [self drainControl]; });
  dispatch_resume(_ctlSource);

  NSString *simns = [ExecutableDir() stringByAppendingPathComponent:@"simns"];
  NSMutableArray *env = [NSMutableArray array];
  for (char **e = environ; *e; e++)
    if (strncmp(*e, "DYLD_INSERT_LIBRARIES=", 22) && strncmp(*e, "SIMNS_HOST_SLOT=", 16)) [env addObject:@(*e)];
  [env addObject:@"SIMNS_HOST_SLOT=0"];
  char **cenv = calloc(env.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < env.count; i++) cenv[i] = (char *)[env[i] UTF8String];
  char *argv[] = { (char *)simns.UTF8String, "--serve", NULL };
  mach_port_t reg[1] = { _ctlPort };
  mach_ports_register(mach_task_self(), reg, 1);   // simns finds us in slot 0 and says hello
  int r = posix_spawn(&_simnsPid, argv[0], NULL, NULL, argv, cenv);
  mach_ports_register(mach_task_self(), NULL, 0);
  free(cenv);
  if (r) { LOG(@"spawn %@: %s", simns, strerror(r)); return NO; }
  LOG(@"simns pid %d", _simnsPid);
  return YES;
}

- (void)drainControl {
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, _ctlPort, 0, 0) == KERN_SUCCESS) {
    if (m.h.msgh_id != SIMNS_MSG_HELLO) { mach_msg_destroy(&m.h); continue; }
    _nsCtl = m.p.port.name;
    mach_port_t ios = 0, mtl = 0;
    if (srgpu_host_start(&ios, &mtl) != 0) LOG(@"host GPU services failed to start");
    if (ios) [self registerName:"com.apple.IOSurface.Remote" port:ios];
    if (mtl) [self registerName:"com.apple.metal.simulator" port:mtl];
    mach_msg_header_t ready = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof ready,
                                .msgh_remote_port = _nsCtl, .msgh_id = SIMNS_MSG_READY };
    mach_msg(&ready, MACH_SEND_MSG, sizeof ready, 0, 0, 0, 0);
    LOG(@"ready");
    NSArray *pending = [_pending copy]; [_pending removeAllObjects];
    for (SRRequest *r in pending) [self launch:r];
  }
}

- (void)registerName:(const char *)name port:(mach_port_t)port {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r; r.h.msgh_remote_port = _nsCtl; r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1; r.port.name = port; r.port.disposition = MACH_MSG_TYPE_COPY_SEND; r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  r.flags = SIMNS_F_HOST_SIDE; strlcpy(r.name, name, sizeof r.name);
  mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
}

// A fresh per-app namespace (send right) from simns.
- (mach_port_t)newNamespace {
  mach_port_t reply; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  m.h.msgh_size = sizeof(mach_msg_header_t); m.h.msgh_remote_port = _nsCtl; m.h.msgh_local_port = reply;
  m.h.msgh_id = SIMNS_MSG_NEW_NS;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, sizeof(mach_msg_header_t), sizeof m, reply, 3000, 0);
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  if (kr || m.h.msgh_id != SIMNS_MSG_NS_REPLY) { LOG(@"new namespace failed: %x", kr); return MACH_PORT_NULL; }
  return m.p.port.name;
}

// ---------------------------------------------------------------- launching
- (void)enqueue:(SRRequest *)r {
  [_idleTimer invalidate]; _idleTimer = nil;
  if (_nsCtl) [self launch:r]; else [_pending addObject:r];
}

- (NSArray<NSString *> *)appEnvironmentFrom:(NSArray<NSString *> *)env {
  NSString *insert = nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *kv in env) {
    if ([kv hasPrefix:@"SIMNS_INSERT="]) insert = [kv substringFromIndex:13];
    if ([kv hasPrefix:@"DYLD_INSERT_LIBRARIES="] || [kv hasPrefix:@"XPC_SIMULATOR_LAUNCHD_NAME="] || [kv hasPrefix:@"XPC_FLAGS="] ||
        [kv hasPrefix:@"XPC_SERVICE_NAME="] || [kv hasPrefix:@"SIMNS_"]) continue;
    [out addObject:kv];
  }
  [out addObject:@"XPC_SIMULATOR_LAUNCHD_NAME=dev.simrun.simns"];   // value unused; makes sim libxpc use our bootstrap port
  [out addObject:@"XPC_FLAGS=0x0"];
  if (insert.length) [out addObject:[@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:insert]];
  return out;
}

- (void)launch:(SRRequest *)r {
  SRSession *s = [[SRSession alloc] initWithTitle:r.title ?: @"SimRun"];
  r.session = s;
  [_active addObject:r];
  __weak SRServer *weakSelf = self;
  s.onExit = ^(SRSession *session, int status) { [weakSelf finish:r status:status]; };
  mach_port_t ns = [self newNamespace];
  int fds[3] = { r.fd0, r.fd1, r.fd2 };
  NSString *err = nil;
  BOOL ok = ns && [s spawnArgv:r.argv env:[self appEnvironmentFrom:r.env] cwd:r.cwd bootstrap:ns fds:fds error:&err];
  if (ns) mach_port_deallocate(mach_task_self(), ns);   // the app holds its own send right; simns frees the namespace after it
  for (int i = 0; i < 3; i++) if (fds[i] >= 0) close(fds[i]);
  r.fd0 = r.fd1 = r.fd2 = -1;
  if (!ok) {
    LOG(@"launch failed: %@", err ?: @"no namespace");
    [self reply:r dict:@{ @"error": err ?: @"simns did not create a namespace" }];
    [s terminate]; [_active removeObject:r]; [self closeClient:r];
    if (_runMode) exit(1);
    [self scheduleIdleCheck];
    return;
  }
  LOG(@"launched %@ pid %d", r.argv.firstObject.lastPathComponent, s.pid);
  [self reply:r dict:@{ @"pid": @(s.pid) }];
}

- (void)finish:(SRRequest *)r status:(int)status {
  LOG(@"%@ (pid %d) exited, status %d", r.title, r.session.pid, status);
  [self reply:r dict:@{ @"exit": @(status) }];
  [self closeClient:r];
  [_active removeObject:r];
  if (_runMode) exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
  [self scheduleIdleCheck];
}

// ---------------------------------------------------------------- client connections
- (BOOL)startListening {
  char path[1024]; simrund_socket_path(path, sizeof path);
  _socketPath = @(path);
  [NSFileManager.defaultManager createDirectoryAtPath:_socketPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  struct sockaddr_un a = { .sun_family = AF_UNIX }; strlcpy(a.sun_path, path, sizeof a.sun_path);
  // a live server already listening? then we're redundant
  int probe = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(probe, (struct sockaddr *)&a, sizeof a) == 0) { close(probe); LOG(@"another simrund is serving %s", path); return NO; }
  close(probe);
  unlink(path);
  _listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (bind(_listenFd, (struct sockaddr *)&a, sizeof a) || listen(_listenFd, 16)) { LOG(@"bind %s: %s", path, strerror(errno)); return NO; }
  chmod(path, 0600);
  _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenFd, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_listenSource, ^{
    int c = accept(self->_listenFd, NULL, NULL);
    if (c >= 0) [self readRequestFrom:c];
  });
  dispatch_resume(_listenSource);
  LOG(@"serving %s", path);
  return YES;
}

- (void)readRequestFrom:(int)c {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    int fds[3] = { -1, -1, -1 }, nfds = 0;
    CFDictionaryRef req = simrund_recv(c, fds, &nfds);
    int f0 = fds[0], f1 = fds[1], f2 = fds[2];
    dispatch_async(dispatch_get_main_queue(), ^{
      int got[3] = { f0, f1, f2 };
      NSDictionary *d = CFBridgingRelease(req);
      NSArray *argv = d[@"argv"];
      if (![argv isKindOfClass:NSArray.class] || !argv.count || nfds != 3) {
        for (int i = 0; i < nfds; i++) close(got[i]);
        close(c); return;
      }
      SRRequest *r = [SRRequest new];
      r.argv = argv; r.env = d[@"env"] ?: @[]; r.cwd = d[@"cwd"]; r.title = d[@"title"];
      r.sock = c; r.fd0 = got[0]; r.fd1 = got[1]; r.fd2 = got[2];
      // client gone (e.g. Ctrl-C) before the app exited -> terminate the app
      dispatch_source_t eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, c, 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(eof, ^{
        char b; if (recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0) { dispatch_source_cancel(eof); [r.session terminate]; }
      });
      dispatch_resume(eof); r.eofSource = eof;
      [self enqueue:r];
    });
  });
}

- (void)reply:(SRRequest *)r dict:(NSDictionary *)d {
  if (r.sock >= 0) simrund_send(r.sock, (__bridge CFDictionaryRef)d, NULL, 0);
}
- (void)closeClient:(SRRequest *)r {
  if (r.eofSource) { dispatch_source_cancel(r.eofSource); r.eofSource = nil; }
  if (r.sock >= 0) { close(r.sock); r.sock = -1; }
}

// ---------------------------------------------------------------- lifetime
- (void)scheduleIdleCheck {
  if (_runMode || _active.count || _pending.count) return;
  const char *e = getenv("SIMRUND_IDLE");
  double idle = e ? atof(e) : 600;
  if (idle <= 0) return;
  [_idleTimer invalidate];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:idle repeats:NO block:^(NSTimer *t) {
    if (!self->_active.count && !self->_pending.count) { LOG(@"idle for %.0f s, exiting", idle); [NSApp terminate:nil]; }
  }];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }
- (void)applicationWillTerminate:(NSNotification *)n {
  for (SRRequest *r in _active) { [r.session terminate]; [self reply:r dict:@{ @"error": @"simrund quit" }]; }
  if (_simnsPid > 0) kill(_simnsPid, SIGTERM);
  if (_listenFd >= 0 && _socketPath) unlink(_socketPath.fileSystemRepresentation);
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    BOOL run = argc >= 3 && !strcmp(argv[1], "--run");
    if (!run && !(argc == 2 && !strcmp(argv[1], "--serve"))) {
      fprintf(stderr, "usage: simrund --serve | simrund --run <sim-binary> [args...]\n"); return 2;
    }
    NSMutableArray *rest = [NSMutableArray array];
    for (int i = 2; i < argc; i++) [rest addObject:@(argv[i])];
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    SRServer *server = [[SRServer alloc] initRunMode:run argv:rest];
    app.delegate = server;
    [app run];
  }
}
