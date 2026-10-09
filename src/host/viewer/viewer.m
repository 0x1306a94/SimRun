// SimRun viewer (host, AppKit): spawns a sim process, displays its IOSurface, forwards input.
// usage: viewer <sim-binary-or-launcher> [args...]   (env for the child is inherited; use simrun.sh as argv[1])
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include <spawn.h>
#include <objc/runtime.h>
#include "protocol.h"
#include "simns_proto.h"
#include "gpuhost.h"
#include <xpc/xpc.h>

extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
@interface IOSurfaceRemoteServer : NSObject
- (instancetype)initWithListener:(xpc_connection_t)listener options:(NSDictionary *)options;
@end
extern char **environ;

@interface SRView : NSView
@property mach_port_t inputPort;
@property CGFloat simScale;
@end
@implementation SRView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)send:(uint32_t)kind event:(NSEvent *)e {
  if (!self.inputPort) return;
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  sr_input_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = self.inputPort; m.h.msgh_id = SR_MSG_INPUT;
  m.kind = kind; m.x = p.x; m.y = p.y;   // points in sim UI coordinate space (view is 1:1 with sim points)
  if (kind == SR_IN_KEY_DOWN || kind == SR_IN_KEY_UP) {
    m.keycode = e.keyCode; m.modifiers = (uint32_t)e.modifierFlags;
    strlcpy(m.text, e.characters.UTF8String ?: "", sizeof m.text);
  }
  mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 0, 0);
}
- (void)mouseDown:(NSEvent *)e { [self send:SR_IN_TOUCH_BEGAN event:e]; }
- (void)mouseDragged:(NSEvent *)e { [self send:SR_IN_TOUCH_MOVED event:e]; }
- (void)mouseUp:(NSEvent *)e { [self send:SR_IN_TOUCH_ENDED event:e]; }
- (void)scrollWheel:(NSEvent *)e {
  if (!self.inputPort) return;
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  sr_input_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = self.inputPort; m.h.msgh_id = SR_MSG_INPUT;
  m.kind = SR_IN_SCROLL; m.x = p.x; m.y = p.y;
  float d[2] = { (float)e.scrollingDeltaX, (float)e.scrollingDeltaY };
  if (!e.hasPreciseScrollingDeltas) { d[0] *= 10; d[1] *= 10; }
  memcpy(m.text, d, sizeof d);
  mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 0, 0);
}
- (void)keyDown:(NSEvent *)e { [self send:SR_IN_KEY_DOWN event:e]; }
- (void)keyUp:(NSEvent *)e { [self send:SR_IN_KEY_UP event:e]; }
@end

@interface SRApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window; @property SRView *view; @property CALayer *surfaceLayer;
@property mach_port_t hostPort; @property pid_t child; @property id iosurfaceServer; @property dispatch_source_t src; @property IOSurfaceRef surface; @property NSMutableDictionary<NSNumber *, id> *surfaces; @property NSSize contentSize;
@end
@implementation SRApp
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 402, 874)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
  self.window.title = NSProcessInfo.processInfo.environment[@"SIMRUN_TITLE"] ?: @"SimRun";
  self.window.delegate = self;
  self.view = [[SRView alloc] initWithFrame:self.window.contentView.bounds];
  self.view.wantsLayer = YES; self.view.layer.backgroundColor = NSColor.blackColor.CGColor;
  self.window.contentView = self.view;
  self.surfaceLayer = [CALayer layer];
  self.surfaceLayer.frame = self.view.bounds; self.surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  self.surfaceLayer.contentsGravity = kCAGravityResize;
  // No implicit animations: every frame swaps `contents`, which would otherwise cross-fade for 0.25 s.
  self.surfaceLayer.actions = @{ @"contents": NSNull.null, @"contentsScale": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null };
  self.surfaces = [NSMutableDictionary dictionary];
  [self.view.layer addSublayer:self.surfaceLayer];
  [self placeNextToOtherViewers];
  [self.window makeKeyAndOrderFront:nil];
  [self.window makeFirstResponder:self.view];
  [NSApp activateIgnoringOtherApps:YES];
  [self spawn];
}
// Several apps can run at once (one viewer per app): put this window to the right of the other viewers' windows
// instead of on top of them, wrapping to a cascade when the screen is full.
- (void)placeNextToOtherViewers {
  NSString *me = NSProcessInfo.processInfo.processName;
  pid_t mypid = getpid();
  NSArray *infos = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  CGFloat maxX = 0, top = 0; int n = 0;
  for (NSDictionary *w in infos) {
    if (![w[(id)kCGWindowOwnerName] isEqual:me] || [w[(id)kCGWindowOwnerPID] intValue] == mypid || [w[(id)kCGWindowLayer] intValue] != 0) continue;
    CGRect b; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b) || b.size.height < 100) continue;
    if (CGRectGetMaxX(b) > maxX) { maxX = CGRectGetMaxX(b); top = b.origin.y; }
    n++;
  }
  if (!n) return;
  NSRect screen = NSScreen.mainScreen.visibleFrame, full = NSScreen.mainScreen.frame;
  NSPoint topLeft = NSMakePoint(maxX + 16, NSMaxY(full) - top);   // CG window bounds are top-left based
  if (topLeft.x + self.window.frame.size.width > NSMaxX(screen))  // no room: cascade from the left edge
    topLeft = NSMakePoint(NSMinX(screen) + 24 * n, NSMaxY(screen) - 24 * n);
  [self.window setFrameTopLeftPoint:topLeft];
}
- (void)spawn {
  mach_port_t rp; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
  mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
  self.hostPort = rp;
  mach_port_t reg[1] = { rp }; mach_ports_register(mach_task_self(), reg, 1);
  NSArray *args = NSProcessInfo.processInfo.arguments;
  char **argv = calloc(args.count, sizeof(char *));
  for (NSUInteger i = 1; i < args.count; i++) argv[i - 1] = strdup([args[i] UTF8String]);
  pid_t pid; int r = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
  mach_ports_register(mach_task_self(), NULL, 0);
  NSLog(@"spawned %s pid=%d r=%d", argv[0], pid, r);
  self.child = pid;
  dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, rp, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(s, ^{ [self drain]; });
  dispatch_resume(s); self.src = s;
  if (getenv("SIMRUN_DEBUG")) [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { mach_port_status_t st; mach_msg_type_number_t c = MACH_PORT_RECEIVE_STATUS_COUNT; mach_port_get_attributes(mach_task_self(), rp, MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&st, &c); NSLog(@"port %x qlen=%u srights=%u", rp, st.mps_msgcount, st.mps_srights); [self drain]; }];
  dispatch_source_t ps = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(ps, ^{ int st; waitpid(pid, &st, 0); NSLog(@"child exited status=%d", st); [NSApp terminate:nil]; });
  dispatch_resume(ps); objc_setAssociatedObject(self, "ps", ps, OBJC_ASSOCIATION_RETAIN);
}
- (void)drain {
  union { mach_msg_header_t h; sr_port_msg_t p; sr_frame_msg_t f; char buf[1024]; } m;
  kern_return_t kr;
  while ((kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, self.hostPort, 0, 0)) == KERN_SUCCESS) {
    if (getenv("SIMRUN_DEBUG")) NSLog(@"msg id=%x size=%u", m.h.msgh_id, m.h.msgh_size);
    switch (m.h.msgh_id) {
      case SIMNS_MSG_HELLO: [self provideHostServices:m.p.port.name]; break;
      case SR_MSG_HELLO: self.view.inputPort = m.p.port.name; NSLog(@"child input port %x", m.p.port.name); break;
      case SR_MSG_SURFACE: {
        // CA rotates between up to 3 framebuffers, so this arrives on most frames: cache surfaces by id.
        IOSurfaceRef s = IOSurfaceLookupFromMachPort(m.p.port.name);
        mach_port_deallocate(mach_task_self(), m.p.port.name);
        if (!s) break;
        NSNumber *key = @(IOSurfaceGetID(s));
        id cached = self.surfaces[key];
        if (cached) CFRelease(s); else { self.surfaces[key] = (__bridge_transfer id)s; cached = self.surfaces[key]; }
        self.surface = (__bridge IOSurfaceRef)cached;
        CGFloat sc = m.p.scale > 0 ? m.p.scale : 3;
        NSSize content = NSMakeSize(m.p.w / sc, m.p.h_px / sc);
        if (!NSEqualSizes(content, self.contentSize)) {
          self.contentSize = content;
          NSLog(@"display %ux%u @%gx", m.p.w, m.p.h_px, sc);
          NSPoint tl = NSMakePoint(NSMinX(self.window.frame), NSMaxY(self.window.frame));
          [self.window setContentSize:content];
          [self.window setFrameTopLeftPoint:tl];   // keep the window's top-left where it was placed
          self.surfaceLayer.contentsScale = sc;
        }
        break;
      }
      case SR_MSG_FRAME:
        // Re-setting the same IOSurface makes CA pick up the new pixels (actions are disabled on this layer).
        self.surfaceLayer.contents = nil; self.surfaceLayer.contents = (__bridge id)self.surface;
        break;
      default: mach_msg_destroy(&m.h);
    }
  }
}
// Host-side ("sim2host") services the sim frameworks expect launchd_sim to publish.
- (void)registerName:(const char *)name port:(mach_port_t)port ns:(mach_port_t)ns {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r; r.h.msgh_remote_port = ns; r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1; r.port.name = port; r.port.disposition = MACH_MSG_TYPE_COPY_SEND; r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  r.flags = SIMNS_F_HOST_SIDE; strlcpy(r.name, name, sizeof r.name);
  kern_return_t kr = mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
  NSLog(@"registered host service %s (port %x) kr=%x", name, port, kr);
}
- (void)provideHostServices:(mach_port_t)ns {
  static mach_port_t ios, mtl;
  if (!ios && srgpu_host_start(&ios, &mtl) != 0) NSLog(@"srgpu_host_start failed");
  if (ios) [self registerName:"com.apple.IOSurface.Remote" port:ios ns:ns];
  if (mtl) [self registerName:"com.apple.metal.simulator" port:mtl ns:ns];
  mach_msg_header_t ready = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof ready, .msgh_remote_port = ns, .msgh_id = SIMNS_MSG_READY };
  mach_msg(&ready, MACH_SEND_MSG, sizeof ready, 0, 0, 0, 0);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
- (void)applicationWillTerminate:(NSNotification *)n { if (self.child > 0) kill(self.child, SIGTERM); }
@end

int main() {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    SRApp *d = [SRApp new]; app.delegate = d;
    [app run];
  }
}
