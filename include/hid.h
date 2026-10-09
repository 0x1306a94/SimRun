// hid.h — in-process HID injection API exported by hid.dylib (see HID.md).
// All functions are thread-safe: they hop to the main thread (asynchronously, in call order) when called elsewhere.
// Coordinates are window-scene points (the coordinate space of the UIWindowScene, e.g. 402x874 portrait, origin top-left;
// after a rotation the scene's rotated space) — exactly what the viewer sends in sr_input_msg_t.x/y.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { SRHID_TOUCH_BEGAN = 1, SRHID_TOUCH_MOVED = 2, SRHID_TOUCH_ENDED = 3, SRHID_TOUCH_CANCELLED = 4 };

// Single-finger touch (finger 0). began -> moved* -> ended/cancelled.
void SRHIDTouch(int phase, float x, float y);
// Multi-touch: finger in [0, 10). Each call emits one digitizer (hand) event containing every finger currently down,
// with the changed finger flagged, as backboardd does. E.g. pinch = two fingers began, moved..., ended.
void SRHIDTouchFinger(int finger, int phase, float x, float y);

// Scroll wheel / trackpad scroll at (x, y), deltas in scene points (content follows: dy > 0 scrolls content down, as
// with macOS natural scrolling). Emulated with a dedicated virtual finger (index 9) that is lifted 120 ms after the
// last delta, without fling.
void SRHIDScroll(float x, float y, float dx, float dy);

// Hardware keyboard key by USB HID usage (page 7, Keyboard/Keypad), e.g. 0x04 'a', 0x28 Return, 0x2A Backspace,
// 0x4F..0x52 arrows, 0xE0..0xE7 modifiers (send those as separate down/up events, like a real keyboard).
void SRHIDKeyUsage(uint32_t hidUsage, bool down);
// Hardware keyboard key by macOS virtual key code (NSEvent.keyCode / kVK_*) + NSEventModifierFlags. Modifier keys are
// synthesized (pressed/released) so that UIKit's modifier state matches `macModifierFlags` before the key event.
void SRHIDKeyMac(uint16_t macKeyCode, bool down, uint32_t macModifierFlags);
// Release all synthesized modifier keys (e.g. when the host window loses focus).
void SRHIDReleaseModifiers(void);
// Type UTF-8 text: US-ASCII characters become key down/up pairs (with shift as needed); anything else is inserted via
// the active keyboard input delegate (UIKeyboardImpl insertText:), like the software keyboard / IME commit.
void SRHIDText(const char *utf8);

// Start the viewer-protocol receiver (viewer/protocol.h): allocates a receive port, sends SR_MSG_HELLO with it to
// mach_ports_lookup()[SR_PORT_SLOT_HOST], and turns SR_MSG_INPUT messages into the calls above. Called automatically
// by the dylib constructor when a host port exists (disable with HID_NO_RECEIVER=1). Idempotent.
void SRHIDStartReceiver(void);

#ifdef __cplusplus
}
#endif
