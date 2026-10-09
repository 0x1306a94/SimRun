// session.m — window + framebuffer + input for one sim app (see session.h).
#import "session.h"
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include <spawn.h>
#include <sys/wait.h>
#include "protocol.h"

extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);
extern int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);

// ---------------------------------------------------------------- content view: forwards mouse/keyboard to the app
@interface SRView : NSView
@property mach_port_t inputPort;
@end
@implementation SRView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)post:(sr_input_msg_t *)m {
  if (!self.inputPort) return;
  m->h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m->h.msgh_size = sizeof *m;
  m->h.msgh_remote_port = self.inputPort; m->h.msgh_id = SR_MSG_INPUT;
  mach_msg(&m->h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof *m, 0, 0, 0, 0);
}
- (void)send:(uint32_t)kind event:(NSEvent *)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  sr_input_msg_t m = {0};
  m.kind = kind; m.x = p.x; m.y = p.y;   // points in sim UI coordinate space (view is 1:1 with sim points)
  if (kind == SR_IN_KEY_DOWN || kind == SR_IN_KEY_UP) {
    m.keycode = e.keyCode; m.modifiers = (uint32_t)e.modifierFlags;
    strlcpy(m.text, e.characters.UTF8String ?: "", sizeof m.text);
  }
  [self post:&m];
}
- (void)mouseDown:(NSEvent *)e { [self send:SR_IN_TOUCH_BEGAN event:e]; }
- (void)mouseDragged:(NSEvent *)e { [self send:SR_IN_TOUCH_MOVED event:e]; }
- (void)mouseUp:(NSEvent *)e { [self send:SR_IN_TOUCH_ENDED event:e]; }
- (void)scrollWheel:(NSEvent *)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  sr_input_msg_t m = {0};
  m.kind = SR_IN_SCROLL; m.x = p.x; m.y = p.y;
  float d[2] = { (float)e.scrollingDeltaX, (float)e.scrollingDeltaY };
  if (!e.hasPreciseScrollingDeltas) { d[0] *= 10; d[1] *= 10; }
  memcpy(m.text, d, sizeof d);
  [self post:&m];
}
- (void)keyDown:(NSEvent *)e { [self send:SR_IN_KEY_DOWN event:e]; }
- (void)keyUp:(NSEvent *)e { [self send:SR_IN_KEY_UP event:e]; }
@end

// ---------------------------------------------------------------- session
@implementation SRSession {
  NSWindow *_window; SRView *_view; CALayer *_surfaceLayer;
  mach_port_t _port; dispatch_source_t _portSource, _procSource;
  IOSurfaceRef _surface; NSMutableDictionary<NSNumber *, id> *_surfaces; NSSize _contentSize;
  BOOL _exited, _sawFrame;
  CFAbsoluteTime _spawnTime;
}

- (instancetype)initWithTitle:(NSString *)title {
  if (!(self = [super init])) return nil;
  _title = [title copy];
  _surfaces = [NSMutableDictionary dictionary];
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 402, 874)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
  _window.title = title; _window.delegate = self; _window.releasedWhenClosed = NO;
  _view = [[SRView alloc] initWithFrame:_window.contentView.bounds];
  _view.wantsLayer = YES; _view.layer.backgroundColor = NSColor.blackColor.CGColor;
  _window.contentView = _view;
  _surfaceLayer = [CALayer layer];
  _surfaceLayer.frame = _view.bounds; _surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  _surfaceLayer.contentsGravity = kCAGravityResize;
  // No implicit animations: every frame swaps `contents`, which would otherwise cross-fade for 0.25 s.
  _surfaceLayer.actions = @{ @"contents": NSNull.null, @"contentsScale": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null };
  [_view.layer addSublayer:_surfaceLayer];
  [self placeWindow];
  [_window makeKeyAndOrderFront:nil];
  [_window makeFirstResponder:_view];
  [NSApp activateIgnoringOtherApps:YES];

  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_port);
  mach_port_insert_right(mach_task_self(), _port, _port, MACH_MSG_TYPE_MAKE_SEND);
  _portSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _port, 0, dispatch_get_main_queue());
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(_portSource, ^{ [weakSelf drain]; });
  dispatch_resume(_portSource);
  return self;
}

// Put the window to the right of the other app windows (this process's and any standalone viewers'),
// cascading from the left edge when the screen is full.
- (void)placeWindow {
  NSArray *infos = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSSet *owners = [NSSet setWithObjects:NSProcessInfo.processInfo.processName, @"viewer", nil];
  CGFloat maxX = 0, top = 0; int n = 0;
  for (NSDictionary *w in infos) {
    if (![owners containsObject:w[(id)kCGWindowOwnerName]] || [w[(id)kCGWindowLayer] intValue] != 0) continue;
    if ([w[(id)kCGWindowNumber] integerValue] == _window.windowNumber) continue;
    CGRect b; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b) || b.size.height < 100) continue;
    if (CGRectGetMaxX(b) > maxX) { maxX = CGRectGetMaxX(b); top = b.origin.y; }
    n++;
  }
  if (!n) return;
  NSRect screen = NSScreen.mainScreen.visibleFrame, full = NSScreen.mainScreen.frame;
  NSPoint topLeft = NSMakePoint(maxX + 16, NSMaxY(full) - top);   // CG window bounds are top-left based
  if (topLeft.x + _window.frame.size.width > NSMaxX(screen))
    topLeft = NSMakePoint(NSMinX(screen) + 24 * n, NSMaxY(screen) - 24 * n);
  [_window setFrameTopLeftPoint:topLeft];
}

- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error {
  char **cargv = calloc(argv.count + 1, sizeof(char *)), **cenv = calloc(env.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = (char *)argv[i].UTF8String;
  for (NSUInteger i = 0; i < env.count; i++) cenv[i] = (char *)env[i].UTF8String;
  posix_spawnattr_t attr; posix_spawnattr_init(&attr);
  if (bootstrap) posix_spawnattr_setspecialport_np(&attr, bootstrap, TASK_BOOTSTRAP_PORT);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++) if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&fa, fds[i], i);
  if (cwd.length) posix_spawn_file_actions_addchdir_np(&fa, cwd.UTF8String);
  // The app's components find this session's port in mach_ports_lookup()[0]; registered ports are inherited by
  // posix_spawn children. Process-wide, so spawns are serialized on the main thread.
  mach_port_t reg[1] = { _port };
  mach_ports_register(mach_task_self(), reg, 1);
  pid_t pid = 0; int r = posix_spawn(&pid, cargv[0], &fa, &attr, cargv, cenv);
  mach_ports_register(mach_task_self(), NULL, 0);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr);
  free(cargv); free(cenv);
  if (r) { if (error) *error = [NSString stringWithFormat:@"spawn %@: %s", argv.firstObject, strerror(r)]; return NO; }
  _pid = pid; _spawnTime = CFAbsoluteTimeGetCurrent();
  _procSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(_procSource, ^{ [weakSelf reap]; });
  dispatch_resume(_procSource);
  return YES;
}

- (void)reap {
  if (_exited) return;
  int st = 0; if (waitpid(_pid, &st, 0) < 0) st = 0;
  _exited = YES;
  dispatch_source_cancel(_procSource); dispatch_source_cancel(_portSource);
  mach_port_mod_refs(mach_task_self(), _port, MACH_PORT_RIGHT_RECEIVE, -1);
  mach_port_deallocate(mach_task_self(), _port);
  if (_view.inputPort) mach_port_deallocate(mach_task_self(), _view.inputPort);
  _window.delegate = nil; [_window close];
  if (self.onExit) self.onExit(self, st);
}

// UIKit apps ignore SIGTERM (termination normally comes through FrontBoard/RunningBoard), so escalate to SIGKILL.
- (void)terminate {
  if (_pid <= 0 || _exited) return;
  kill(_pid, SIGTERM);
  pid_t pid = _pid; __weak SRSession *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SRSession *s = weakSelf;
    if (s && !s->_exited && s->_pid == pid) kill(pid, SIGKILL);
  });
}
- (void)windowWillClose:(NSNotification *)n { [self terminate]; }

- (void)drain {
  union { mach_msg_header_t h; sr_port_msg_t p; sr_frame_msg_t f; char buf[1024]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, _port, 0, 0) == KERN_SUCCESS) {
    switch (m.h.msgh_id) {
      case SR_MSG_HELLO:
        if (_view.inputPort) mach_port_deallocate(mach_task_self(), _view.inputPort);
        _view.inputPort = m.p.port.name;
        break;
      case SR_MSG_SURFACE: {
        // CA rotates between up to 3 framebuffers, so this arrives on most frames: cache surfaces by id.
        IOSurfaceRef s = IOSurfaceLookupFromMachPort(m.p.port.name);
        mach_port_deallocate(mach_task_self(), m.p.port.name);
        if (!s) break;
        NSNumber *key = @(IOSurfaceGetID(s));
        id cached = _surfaces[key];
        if (cached) CFRelease(s); else { _surfaces[key] = (__bridge_transfer id)s; cached = _surfaces[key]; }
        _surface = (__bridge IOSurfaceRef)cached;
        CGFloat sc = m.p.scale > 0 ? m.p.scale : 3;
        NSSize content = NSMakeSize(m.p.w / sc, m.p.h_px / sc);
        if (!NSEqualSizes(content, _contentSize)) {
          _contentSize = content;
          NSPoint tl = NSMakePoint(NSMinX(_window.frame), NSMaxY(_window.frame));
          [_window setContentSize:content];
          [_window setFrameTopLeftPoint:tl];   // keep the window's top-left where it was placed
          _surfaceLayer.contentsScale = sc;
        }
        break;
      }
      case SR_MSG_FRAME:
        if (!_sawFrame) {
          _sawFrame = YES;
          fprintf(stderr, "[simrund] %s (pid %d) first frame %.3f s after spawn (t=%.3f)\n", _title.UTF8String, _pid,
                  CFAbsoluteTimeGetCurrent() - _spawnTime, CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970);
        }
        // Re-setting the same IOSurface makes CA pick up the new pixels (actions are disabled on this layer).
        _surfaceLayer.contents = nil; _surfaceLayer.contents = (__bridge id)_surface;
        break;
      default: mach_msg_destroy(&m.h);
    }
  }
}
@end
