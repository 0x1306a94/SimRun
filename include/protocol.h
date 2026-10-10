// SimRun host<->sim wire protocol (plain Mach messages).
// Host registers [0]=host receive port (sim -> host) via mach_ports_register before spawning.
// Sim sends SR_MSG_HELLO carrying its own receive port (host -> sim, for input), then SR_MSG_SURFACE with an IOSurface port,
// then SR_MSG_FRAME whenever new content is presented.
//
// Frame ownership: the surfaces sent to the host are *display buffers* owned by the sim side's SimFramebuffer, not CA's
// swapchain buffers (CA reuses those on a fixed rotation whatever the display is doing). An SR_MSG_FRAME may carry a
// send-once reply right (msgh_remote_port on receipt); the host must answer it exactly once with SR_MSG_FRAME_ACK once
// that frame has been on screen long enough that every older frame is off screen (about two refresh intervals after
// showing it). The sim side only rewrites a display buffer older than the newest acknowledged frame.
#pragma once
#include <mach/mach.h>
#define SR_PORT_SLOT_HOST 0
enum { SR_MSG_HELLO = 0x5352000, SR_MSG_SURFACE, SR_MSG_FRAME, SR_MSG_INPUT, SR_MSG_FRAME_ACK };
typedef struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t port; uint32_t w, h_px; float scale; } sr_port_msg_t;
// surface_id/checksum/present_time are optional (a shorter message has only seq); checksum is sr_surface_checksum()
// at present time when the sim side runs with SIMFB_CHECK=1, else 0.
typedef struct { mach_msg_header_t h; uint32_t seq; uint32_t surface_id; uint32_t checksum; uint32_t reserved; uint64_t present_time; } sr_frame_msg_t;
// host -> sim reply to an SR_MSG_FRAME: frames older than on_screen_seq are no longer on screen.
typedef struct { mach_msg_header_t h; uint64_t on_screen_seq; } sr_frame_ack_msg_t;

// Sampled FNV-1a checksum of a BGRA IOSurface (a 64x128 grid of pixels): cheap enough to run per frame, and changes
// whenever a meaningful part of the surface is redrawn. Diagnostic only.
#include <IOSurface/IOSurfaceRef.h>
static inline uint32_t sr_surface_checksum(IOSurfaceRef s) {
  size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *px = (const uint8_t *)IOSurfaceGetBaseAddress(s);
  uint32_t hash = 2166136261u;
  for (size_t gy = 0; gy < 128; gy++)
    for (size_t gx = 0; gx < 64; gx++) {
      uint32_t v = *(const uint32_t *)(px + (gy * h / 128) * bpr + (gx * w / 64) * 4);
      hash = (hash ^ v) * 16777619u;
    }
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hash;
}
enum { SR_IN_TOUCH_BEGAN = 1, SR_IN_TOUCH_MOVED, SR_IN_TOUCH_ENDED, SR_IN_KEY_DOWN, SR_IN_KEY_UP, SR_IN_TEXT, SR_IN_RESIZE, SR_IN_SCROLL };  // SR_IN_SCROLL: x,y cursor; float dx,dy in text[0..7]
typedef struct { mach_msg_header_t h; uint32_t kind; float x, y; uint32_t keycode, modifiers; char text[64]; } sr_input_msg_t;
