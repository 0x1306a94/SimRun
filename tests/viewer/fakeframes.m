// sim-platform test: allocate an IOSurface, draw into it, hand it to the host viewer.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#include "protocol.h"
int main() {
  mach_port_array_t ports; mach_msg_type_number_t n = 0;
  mach_ports_lookup(mach_task_self(), &ports, &n);
  mach_port_t host = n ? ports[SR_PORT_SLOT_HOST] : 0;
  if (!host) { fprintf(stderr, "no host port\n"); return 1; }
  int W = 1206, H = 2622;
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ @"IOSurfaceWidth": @(W), @"IOSurfaceHeight": @(H), @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA') });
  mach_port_t sp = IOSurfaceCreateMachPort(s);
  fprintf(stderr, "surface=%p id=%u port=%x base=%p\n", s, s ? IOSurfaceGetID(s) : 0, sp, s ? IOSurfaceGetBaseAddress(s) : 0);
  sr_port_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = host; m.h.msgh_id = SR_MSG_SURFACE;
  m.b.msgh_descriptor_count = 1; m.port.name = sp; m.port.disposition = MACH_MSG_TYPE_MOVE_SEND; m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  m.w = W; m.h_px = H; m.scale = 3;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, 0, 0, 0); fprintf(stderr, "sent surface kr=%x\n", kr);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  for (uint32_t i = 0; i < 3000; i++) {
    IOSurfaceLock(s, 0, NULL);
    CGContextRef c = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), W, H, 8, IOSurfaceGetBytesPerRow(s), cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(c, 0.1, 0.2, 0.3, 1); CGContextFillRect(c, CGRectMake(0, 0, W, H));
    CGContextSetRGBFillColor(c, 1, 0.5, 0, 1); CGContextFillEllipseInRect(c, CGRectMake((i * 7) % (W - 300), H / 2, 300, 300));
    CGContextRelease(c);
    IOSurfaceUnlock(s, 0, NULL);
    sr_frame_msg_t f = { .h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof f, .msgh_remote_port = host, .msgh_id = SR_MSG_FRAME }, .seq = i };
    mach_msg(&f.h, MACH_SEND_MSG, sizeof f, 0, 0, 0, 0);
    usleep(16000);
  }
}
