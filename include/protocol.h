// SimRun host<->sim wire protocol (plain Mach messages).
// Host registers [0]=host receive port (sim -> host) via mach_ports_register before spawning.
// Sim sends SR_MSG_HELLO carrying its own receive port (host -> sim, for input), then SR_MSG_SURFACE with an IOSurface port,
// then SR_MSG_FRAME (no body) whenever new content is presented.
#pragma once
#include <mach/mach.h>
#define SR_PORT_SLOT_HOST 0
enum { SR_MSG_HELLO = 0x5352000, SR_MSG_SURFACE, SR_MSG_FRAME, SR_MSG_INPUT };
typedef struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t port; uint32_t w, h_px; float scale; } sr_port_msg_t;
typedef struct { mach_msg_header_t h; uint32_t seq; } sr_frame_msg_t;
enum { SR_IN_TOUCH_BEGAN = 1, SR_IN_TOUCH_MOVED, SR_IN_TOUCH_ENDED, SR_IN_KEY_DOWN, SR_IN_KEY_UP, SR_IN_TEXT, SR_IN_RESIZE, SR_IN_SCROLL };  // SR_IN_SCROLL: x,y cursor; float dx,dy in text[0..7]
typedef struct { mach_msg_header_t h; uint32_t kind; float x, y; uint32_t keycode, modifiers; char text[64]; } sr_input_msg_t;
