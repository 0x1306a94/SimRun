// rhost: minimal HOST launcher / stand-in for the viewer, for the render prototype.
//   [RHOST_INSERT=dylib] [RHOST_PNG=out.png] rhost <sim-binary | path/to/launchd/simns sim-binary> [args...]
// 1. starts gpuhost services (IOSurface remote server + Metal sim host, sim2host listeners) in this process;
// 2. mach_ports_register slots: [0] = our receive port (viewer protocol + simns HELLO), [1] IOSurface, [2] Metal listener
//    (RHOST_NO_SLOTS=1: leave 1/2 empty so the sim side must find the services through simns registrations);
// 3. env = `../simrun.sh /usr/bin/env -0` (+DYLD_INSERT_LIBRARIES=$RHOST_INSERT, +SIMNS_HOST_SLOT=0);
// 4. posix_spawns argv[1] DIRECTLY (registered ports do not survive the zsh exec in simrun.sh);
// 5. serves: SIMNS_MSG_HELLO -> registers com.apple.IOSurface.Remote + com.apple.metal.simulator into simns, sends READY;
//    SR_MSG_SURFACE/SR_MSG_FRAME (viewer/protocol.h) -> keeps the latest surface, counts frames; on child exit writes
//    the last presented frame to $RHOST_PNG from the HOST side (proves cross-process IOSurface sharing).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#include <spawn.h>
#include <sys/wait.h>
#include "gpuhost.h"
#include "protocol.h"
#include "simns_proto.h"

static mach_port_t gIOS, gMTL, gHP; static IOSurfaceRef gSurf; static unsigned gFrames;

static void ns_register(mach_port_t ns, const char *name, mach_port_t port) {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r; r.h.msgh_remote_port = ns; r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1; r.port.name = port; r.port.disposition = MACH_MSG_TYPE_COPY_SEND; r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  r.flags = SIMNS_F_HOST_SIDE; strlcpy(r.name, name, sizeof r.name);
  kern_return_t kr = mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
  fprintf(stderr, "[rhost] simns register %s -> %#x kr=%#x\n", name, port, kr);
}
static void write_png(IOSurfaceRef s, const char *path) {
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef c = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8, bpr, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
  CGImageRef img = CGBitmapContextCreateImage(c);
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], CFSTR("public.png"), 1, NULL);
  CGImageDestinationAddImage(d, img, NULL); bool ok = CGImageDestinationFinalize(d);
  fprintf(stderr, "[rhost] host-side PNG %s (%zux%zu, IOSurface id %u) %s\n", path, w, h, IOSurfaceGetID(s), ok ? "ok" : "FAILED");
  CFRelease(d); CGImageRelease(img); CGContextRelease(c); CGColorSpaceRelease(cs);
}
static void drain(void) {
  union { mach_msg_header_t h; sr_port_msg_t p; simns_port_msg_t ns; char buf[2048]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, gHP, 0, 0) == KERN_SUCCESS) {
    switch (m.h.msgh_id) {
      case SIMNS_MSG_HELLO: {
        mach_port_t ns = m.ns.port.name;
        ns_register(ns, "com.apple.IOSurface.Remote", gIOS);
        ns_register(ns, "com.apple.metal.simulator", gMTL);
        mach_msg_header_t ready = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof ready,
                                    .msgh_remote_port = ns, .msgh_id = SIMNS_MSG_READY };
        mach_msg(&ready, MACH_SEND_MSG, sizeof ready, 0, 0, 0, 0);
        break;
      }
      case SR_MSG_SURFACE:
        if (gSurf) CFRelease(gSurf);
        gSurf = IOSurfaceLookupFromMachPort(m.p.port.name);
        mach_port_deallocate(mach_task_self(), m.p.port.name);
        static int nlog; if (nlog++ < 3) fprintf(stderr, "[rhost] viewer protocol: surface %ux%u @%gx -> IOSurface id %u\n", m.p.w, m.p.h_px, m.p.scale, gSurf ? IOSurfaceGetID(gSurf) : 0);
        break;
      case SR_MSG_FRAME: gFrames++; break;
      default: mach_msg_destroy(&m.h);
    }
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: [RHOST_INSERT=dylib] rhost <sim-binary|simns sim-binary> [args...]\n"); return 2; }
    if (srgpu_host_start(&gIOS, &gMTL) != 0) return 1;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gHP);
    mach_port_insert_right(mach_task_self(), gHP, gHP, MACH_MSG_TYPE_MAKE_SEND);
    BOOL noSlots = getenv("RHOST_NO_SLOTS") != NULL;
    mach_port_t slots[3] = { gHP, noSlots ? MACH_PORT_NULL : gIOS, noSlots ? MACH_PORT_NULL : gMTL };
    kern_return_t kr = mach_ports_register(mach_task_self(), slots, 3);
    if (kr) fprintf(stderr, "[rhost] mach_ports_register: %s\n", mach_error_string(kr));
    NSString *simrun = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../scripts/simrun.sh"];
    if (getenv("SIMRUN_SH")) simrun = @(getenv("SIMRUN_SH"));
    setenv("SIMNS_HOST_SLOT", "0", 0);
    char **env = srgpu_sim_environment(simrun.UTF8String, getenv("RHOST_INSERT"));
    pid_t pid; int r = posix_spawn(&pid, argv[1], NULL, NULL, argv + 1, env);
    if (r) { fprintf(stderr, "[rhost] spawn %s: %s\n", argv[1], strerror(r)); return 1; }
    dispatch_source_t ms = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gHP, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(ms, ^{ drain(); }); dispatch_resume(ms);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
      int status = 0; waitpid(pid, &status, 0); drain();
      if (gFrames) fprintf(stderr, "[rhost] viewer protocol: %u SR_MSG_FRAME received\n", gFrames);
      if (gSurf && getenv("RHOST_PNG")) write_png(gSurf, getenv("RHOST_PNG"));
      exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    });
    dispatch_resume(s);
    dispatch_main();
  }
}
