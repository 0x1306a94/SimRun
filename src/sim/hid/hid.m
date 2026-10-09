// hid.dylib — in-process HID input for iOS-Simulator UIKit apps run without backboardd/SpringBoard (see HID.md).
//
// Injection point: -[UIApplication _enqueueHIDEvent:] (= -[UIEventFetcher _receiveHIDEvent:]), the same entry that
// backboardd-delivered events take (BKSHIDEventRegisterEventCallbackOnQueue -> _UIEventFetcherReceiveHIDEventCallback
// -> -[UIEventFetcher ingestHIDEvent:] -> filter chain -> UIEventDispatcher -> __dispatchPreprocessedEventFromEventQueue
// -> UITouchesEvent / UIPhysicalKeyboardEvent+UIPressesEvent). We build the IOHIDEvents backboardd would:
//   touches: digitizer "hand" event + one finger child per active touch, BKSHIDEventDigitizerAttributes with the CAContext
//            id of the window under the first finger (BKSHIDEventSetDigitizerInfo);
//   keys:    keyboard events (usage page 7) + BKSHIDEventBaseAttributes {source externalKeyboard, token = key window
//            CAContext id} (BKSHIDEventSetSimpleInfo) — UIKit drops keyboard events whose context id maps to no window.
// Plus the backboardd/SpringBoard state UIKit needs for text input:
//   * GSEventIsHardwareKeyboardAttached() -> YES (interposed; normally notifyd state set by backboardd)
//   * keyboardFocus/system event-deferring chains pushed to BKSHIDEventObserver (normally from backboardd's
//     hid-services BSService) so _UIKeyboardFocusAssistant grants the scene keyboard focus
//   * _UIRemoteKeyboards -queue_failedConnection: swallowed (no SpringBoard keyboard arbiter)
//   * dictation availability forced off (AssistantServices livelock without assistantd)
// and a receiver for the viewer protocol (viewer/protocol.h SR_MSG_INPUT).
//
// Exports: hid.h. Env: HID_VERBOSE, HID_NO_RECEIVER, HID_SCRIPT="cmd; cmd; ..." (SRHIDRunScript), HID_DEMO (HIDTest
// script), HID_SOFTWARE_KEYBOARD, HID_NO_FOCUS, HID_KEEP_DICTATION, HID_KEEP_REMOTE_KEYBOARDS, HID_KB_SOURCE.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <dlfcn.h>
#include "hid.h"
#include "protocol.h"

#define LOG(fmt, ...) fprintf(stderr, "[hid] " fmt "\n", ##__VA_ARGS__)
static int gVerbose;
#define VLOG(fmt, ...) do { if (gVerbose) LOG(fmt, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- IOKit (IOHIDEvent) / BackBoardServices private API
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducerType, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist, Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t usagePage, uint32_t usage, Boolean down, uint32_t flags);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t field, IOHIDFloat value);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t senderID);
// (event, contextID, systemGesturesPossible, systemGestureStateChange, displayUUID, initialTouchTimestamp, maxForce)
extern void BKSHIDEventSetDigitizerInfo(IOHIDEventRef, uint32_t contextID, Boolean systemGesturePossible, Boolean systemGestureStateChange,
    CFStringRef displayUUID, double initialTouchTimestamp, double maxForce);

// (event, BKSHIDEventSource, options(1 = ?), displayHardwareIdentifier, contextID, systemEnvironment) -> BKSHIDEventBaseAttributes
extern void BKSHIDEventSetSimpleInfo(IOHIDEventRef, uint32_t source, int options, CFStringRef display, uint32_t contextID, Boolean systemEnv);
extern NSString *NSStringFromBKSHIDEventSource(uint32_t);
enum { kTransducerFinger = 2, kTransducerHand = 3 };
enum { kMaskRange = 0x1, kMaskTouch = 0x2, kMaskPosition = 0x4, kMaskIdentity = 0x20, kMaskCancel = 0x80 };
#define kHIDPage_KeyboardOrKeypad 0x07
#define kFieldDigitizerIsDisplayIntegrated ((11 << 16) | 25)   // kIOHIDEventFieldDigitizerIsDisplayIntegrated
#define kFieldDigitizerMajorRadius ((11 << 16) | 20)
#define kFieldDigitizerMinorRadius ((11 << 16) | 21)

// Arbitrary but stable sender IDs (UIKit keys some per-device state, e.g. hardware keyboard tracking, by sender).
static const uint64_t kDigitizerSenderID = 0x000000010000AB1DULL;
static const uint64_t kKeyboardSenderID  = 0x000000010000AB1EULL;
static uint32_t kKeyboardSource = 1;

@interface NSObject (SRHIDPrivate)
- (void)_enqueueHIDEvent:(IOHIDEventRef)e;
- (uint32_t)_contextId;
+ (id)activeInstance;
- (void)insertText:(NSString *)t;
- (id)firstResponder;
@end

static void SRHIDOnMain(dispatch_block_t b) {
  if (pthread_main_np()) b(); else dispatch_async(dispatch_get_main_queue(), b);
}

// ---------------------------------------------------------------- touch routing (what backboardd's hit-test does)
// backboardd picks the CAContext under the finger at touch-down (CAWindowServer contextIdAtPosition) and keeps it for
// the whole touch. In-process we do the UIKit-level equivalent: topmost visible window of the active scene whose
// -hitTest: returns a view. Windows at the same level: later in UIWindowScene.windows wins.
static UIWindowScene *SRHIDScene(void) {
  UIWindowScene *best = nil;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
    if (![s isKindOfClass:UIWindowScene.class]) continue;
    if (!best || s.activationState == UISceneActivationStateForegroundActive) best = (UIWindowScene *)s;
  }
  return best;
}
static UIWindow *SRHIDWindowAt(CGPoint p) {
  UIWindowScene *ws = SRHIDScene();
  NSArray<UIWindow *> *wins = [ws.windows sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
    return a.windowLevel < b.windowLevel ? NSOrderedDescending : a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedSame;
  }];
  // stable sort keeps original order for equal levels; we want the last-added on top => iterate equal-level runs reversed
  UIWindow *hit = nil; CGFloat level = 0; BOOL have = NO;
  for (UIWindow *w in wins) {
    if (have && w.windowLevel != level) break;
    if (w.hidden || w.alpha < 0.01 || !w.userInteractionEnabled || ![w _contextId]) continue;
    CGPoint lp = [w convertPoint:p fromCoordinateSpace:ws.coordinateSpace];
    if ([w hitTest:lp withEvent:nil]) { hit = w; have = YES; level = w.windowLevel; }
  }
  return hit ?: ws.keyWindow ?: ws.windows.firstObject;
}

// ---------------------------------------------------------------- touches
#define SRHID_MAX_FINGERS 10
typedef struct { bool down; float x, y; uint32_t identity, ctx; } SRFinger;
static SRFinger gFingers[SRHID_MAX_FINGERS];
static uint32_t gNextIdentity = 2;

static void SRHIDTouchFingerMain(int finger, int phase, float x, float y) {
  if (finger < 0 || finger >= SRHID_MAX_FINGERS) return;
  SRFinger *f = &gFingers[finger];
  if (phase == SRHID_TOUCH_BEGAN) {
    if (f->down) SRHIDTouchFingerMain(finger, SRHID_TOUCH_ENDED, f->x, f->y); // missing end: close the old touch
    UIWindow *w = SRHIDWindowAt(CGPointMake(x, y));
    if (!w) { VLOG("touch began but no window"); return; }
    // all fingers of one hand event must share the context; join an existing touch's context if any
    uint32_t ctx = [w _contextId];
    for (int i = 0; i < SRHID_MAX_FINGERS; i++) if (gFingers[i].down) { ctx = gFingers[i].ctx; break; }
    *f = (SRFinger){ true, x, y, gNextIdentity++, ctx };
  } else {
    if (!f->down) return; // moved/ended without began: ignore
    f->x = x; f->y = y;
  }
  bool ending = phase == SRHID_TOUCH_ENDED || phase == SRHID_TOUCH_CANCELLED;
  uint64_t ts = mach_absolute_time();
  uint32_t changedMask = phase == SRHID_TOUCH_MOVED ? kMaskPosition : (kMaskRange | kMaskTouch | kMaskIdentity);
  if (phase == SRHID_TOUCH_CANCELLED) changedMask |= kMaskCancel;
  // Hand (parent) event: position of the changed finger, touch/range = any finger still touching after this event.
  bool anyTouching = !ending;
  for (int i = 0; i < SRHID_MAX_FINGERS; i++) if (i != finger && gFingers[i].down) anyTouching = true;
  IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kTransducerHand, 0, 0, changedMask, 0, x, y, 0, 0, 0,
                                                      anyTouching, anyTouching, 0);
  IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
  for (int i = 0; i < SRHID_MAX_FINGERS; i++) {
    SRFinger *g = &gFingers[i];
    if (!g->down) continue;
    bool changed = i == finger;
    bool touching = !(changed && ending);
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, (uint32_t)i + 1, g->identity, changed ? changedMask : 0,
                                                               g->x, g->y, 0, touching ? 1 : 0, 0, touching, touching, 0);
    IOHIDEventSetFloatValue(child, kFieldDigitizerMajorRadius, 5.0);
    IOHIDEventSetFloatValue(child, kFieldDigitizerMinorRadius, 5.0);
    IOHIDEventAppendEvent(hand, child, 0);
    CFRelease(child);
  }
  IOHIDEventSetSenderID(hand, kDigitizerSenderID);
  BKSHIDEventSetDigitizerInfo(hand, f->ctx, false, false, NULL, 0, 0);
  VLOG("touch finger=%d phase=%d (%.1f,%.1f) ctx=0x%x", finger, phase, x, y, f->ctx);
  [UIApplication.sharedApplication _enqueueHIDEvent:hand];
  CFRelease(hand);
  if (ending) f->down = false;
}

void SRHIDTouchFinger(int finger, int phase, float x, float y) { SRHIDOnMain(^{ SRHIDTouchFingerMain(finger, phase, x, y); }); }
void SRHIDTouch(int phase, float x, float y) { SRHIDTouchFinger(0, phase, x, y); }

// ---------------------------------------------------------------- scroll wheel / trackpad (emulated)
// iPhone UIKit has no pointer: a wheel/trackpad scroll is emulated as a drag of a dedicated virtual finger
// (SRHID_SCROLL_FINGER) that starts at the cursor, follows the accumulated deltas, and lifts after 120 ms without
// scroll input (holding still first, so UIScrollView does not fling). Content follows the fingers: dy > 0 moves the
// content down (= macOS "natural" scrolling deltas, i.e. NSEvent.scrollingDeltaY as delivered with natural scrolling).
#define SRHID_SCROLL_FINGER 9
static float gScrollX, gScrollY;
static uint64_t gScrollSerial;
static void SRHIDScrollMain(float x, float y, float dx, float dy) {
  SRFinger *f = &gFingers[SRHID_SCROLL_FINGER];
  if (!f->down) { gScrollX = x; gScrollY = y; SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_BEGAN, x, y); if (!f->down) return; }
  gScrollX += dx; gScrollY += dy;
  SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX, gScrollY);
  uint64_t serial = ++gScrollSerial;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if (serial != gScrollSerial || !gFingers[SRHID_SCROLL_FINGER].down) return;
    // kill the velocity before lifting: a few sub-point "still" samples spread over ~60 ms, then lift
    for (int k = 1; k <= 3; k++)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, k * 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (serial != gScrollSerial || !gFingers[SRHID_SCROLL_FINGER].down) return;
        SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX + (k & 1) * 0.05f, gScrollY + (k & 1) * 0.05f);
        if (k == 3) SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_ENDED, gScrollX, gScrollY);
      });
  });
}
void SRHIDScroll(float x, float y, float dx, float dy) { SRHIDOnMain(^{ SRHIDScrollMain(x, y, dx, dy); }); }

// ---------------------------------------------------------------- keyboard
static void SRHIDKeyUsageMain(uint32_t usage, bool down) {
  IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_KeyboardOrKeypad, usage, down, 0);
  IOHIDEventSetSenderID(e, kKeyboardSenderID);
  // keyboard events are routed by backboardd to the keyboard-focus deferring target (the app's key window context);
  // UIKit maps the base attributes' contextID to the window (_UIEventHIDUIWindowForHIDEvent) and drops the event if none.
  UIWindowScene *ws = SRHIDScene();
  UIWindow *kw = ws.keyWindow ?: ws.windows.firstObject;
  BKSHIDEventSetSimpleInfo(e, kKeyboardSource, 0, NULL, kw ? [kw _contextId] : 0, false);
  VLOG("key usage=0x%x %s", usage, down ? "down" : "up");
  [UIApplication.sharedApplication _enqueueHIDEvent:e];
  CFRelease(e);
}
void SRHIDKeyUsage(uint32_t usage, bool down) { SRHIDOnMain(^{ SRHIDKeyUsageMain(usage, down); }); }

// macOS kVK_* -> USB HID usage (page 7). 0 = unmapped.
static const uint8_t kMacToHID[128] = {
  [0x00]=0x04,[0x01]=0x16,[0x02]=0x07,[0x03]=0x09,[0x04]=0x0B,[0x05]=0x0A,[0x06]=0x1D,[0x07]=0x1B,[0x08]=0x06,[0x09]=0x19,
  [0x0A]=0x64,[0x0B]=0x05,[0x0C]=0x14,[0x0D]=0x1A,[0x0E]=0x08,[0x0F]=0x15,[0x10]=0x1C,[0x11]=0x17,[0x12]=0x1E,[0x13]=0x1F,
  [0x14]=0x20,[0x15]=0x21,[0x16]=0x23,[0x17]=0x22,[0x18]=0x2E,[0x19]=0x26,[0x1A]=0x24,[0x1B]=0x2D,[0x1C]=0x25,[0x1D]=0x27,
  [0x1E]=0x30,[0x1F]=0x12,[0x20]=0x18,[0x21]=0x2F,[0x22]=0x0C,[0x23]=0x13,[0x24]=0x28,[0x25]=0x0F,[0x26]=0x0D,[0x27]=0x34,
  [0x28]=0x0E,[0x29]=0x33,[0x2A]=0x31,[0x2B]=0x36,[0x2C]=0x38,[0x2D]=0x11,[0x2E]=0x10,[0x2F]=0x37,[0x30]=0x2B,[0x31]=0x2C,
  [0x32]=0x35,[0x33]=0x2A,[0x35]=0x29,[0x36]=0xE7,[0x37]=0xE3,[0x38]=0xE1,[0x39]=0x39,[0x3A]=0xE2,[0x3B]=0xE0,[0x3C]=0xE5,
  [0x3D]=0xE6,[0x3E]=0xE4,[0x40]=0x6C,[0x41]=0x63,[0x43]=0x55,[0x45]=0x57,[0x47]=0x53,[0x48]=0x80,[0x49]=0x81,[0x4A]=0x7F,
  [0x4B]=0x54,[0x4C]=0x58,[0x4E]=0x56,[0x4F]=0x6D,[0x50]=0x6E,[0x51]=0x67,[0x52]=0x62,[0x53]=0x59,[0x54]=0x5A,[0x55]=0x5B,
  [0x56]=0x5C,[0x57]=0x5D,[0x58]=0x5E,[0x59]=0x5F,[0x5A]=0x6F,[0x5B]=0x60,[0x5C]=0x61,[0x5D]=0x89,[0x5E]=0x87,[0x5F]=0x85,
  [0x60]=0x3E,[0x61]=0x3F,[0x62]=0x40,[0x63]=0x3C,[0x64]=0x41,[0x65]=0x42,[0x66]=0x91,[0x67]=0x44,[0x68]=0x90,[0x69]=0x68,
  [0x6A]=0x6B,[0x6B]=0x69,[0x6D]=0x43,[0x6F]=0x45,[0x71]=0x6A,[0x72]=0x75,[0x73]=0x4A,[0x74]=0x4B,[0x75]=0x4C,[0x76]=0x3D,
  [0x77]=0x4D,[0x78]=0x3B,[0x79]=0x4E,[0x7A]=0x3A,[0x7B]=0x50,[0x7C]=0x4F,[0x7D]=0x51,[0x7E]=0x52,
};
// NSEventModifierFlags bits -> left-hand modifier usages
static const struct { uint32_t flag; uint32_t usage; } kModifiers[] = {
  { 1u << 17, 0xE1 /* shift */ }, { 1u << 18, 0xE0 /* control */ }, { 1u << 19, 0xE2 /* option */ }, { 1u << 20, 0xE3 /* command */ },
};
static uint32_t gModsDown; // NSEventModifierFlags currently pressed (synthesized)
static void SRHIDSyncModifiersMain(uint32_t flags) {
  for (size_t i = 0; i < sizeof kModifiers / sizeof *kModifiers; i++) {
    uint32_t f = kModifiers[i].flag;
    if ((flags & f) && !(gModsDown & f)) { SRHIDKeyUsageMain(kModifiers[i].usage, true); gModsDown |= f; }
    if (!(flags & f) && (gModsDown & f)) { SRHIDKeyUsageMain(kModifiers[i].usage, false); gModsDown &= ~f; }
  }
}
void SRHIDReleaseModifiers(void) { SRHIDOnMain(^{ SRHIDSyncModifiersMain(0); }); }
void SRHIDKeyMac(uint16_t keyCode, bool down, uint32_t flags) {
  SRHIDOnMain(^{
    uint32_t usage = keyCode < 128 ? kMacToHID[keyCode] : 0;
    bool isModifierKey = usage >= 0xE0 && usage <= 0xE7;
    if (!isModifierKey) SRHIDSyncModifiersMain(flags);
    if (keyCode == 0x39) return; // caps lock: toggled by the host, not mirrored
    if (!usage) { VLOG("unmapped mac keyCode 0x%x", keyCode); return; }
    if (isModifierKey) {
      // flagsChanged-style input: keep gModsDown consistent with what we send
      for (size_t i = 0; i < sizeof kModifiers / sizeof *kModifiers; i++)
        if (kModifiers[i].usage == usage || kModifiers[i].usage + 4 == usage) { if (down) gModsDown |= kModifiers[i].flag; else gModsDown &= ~kModifiers[i].flag; }
    }
    SRHIDKeyUsageMain(usage, down);
  });
}

// US-ASCII -> (usage, shift)
static bool SRHIDAsciiToUsage(unichar c, uint32_t *usage, bool *shift) {
  static const char *unshifted = "1234567890-=[]\\;'`,./", *shifted = "!@#$%^&*()_+{}|:\"~<>?";
  static const uint8_t pu[] = { 0x1E,0x1F,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x35,0x36,0x37,0x38 };
  *shift = false;
  if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return true; }
  if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = true; return true; }
  if (c == ' ') { *usage = 0x2C; return true; }
  if (c == '\n' || c == '\r') { *usage = 0x28; return true; }
  if (c == '\t') { *usage = 0x2B; return true; }
  if (c == 0x08 || c == 0x7F) { *usage = 0x2A; return true; }
  if (c == 0x1B) { *usage = 0x29; return true; }
  for (int i = 0; unshifted[i]; i++) if (unshifted[i] == c) { *usage = pu[i]; return true; }
  for (int i = 0; shifted[i]; i++) if (shifted[i] == c) { *usage = pu[i]; *shift = true; return true; }
  return false;
}
static void SRHIDInsertTextMain(NSString *s) {
  id kb = [NSClassFromString(@"UIKeyboardImpl") activeInstance];
  if (kb && [kb respondsToSelector:@selector(insertText:)]) { [kb insertText:s]; return; }
  id fr = [SRHIDScene().keyWindow firstResponder];
  if ([fr conformsToProtocol:@protocol(UIKeyInput)]) [(id<UIKeyInput>)fr insertText:s];
  else VLOG("text \"%s\" dropped: no text input responder", s.UTF8String);
}
void SRHIDText(const char *utf8) {
  NSString *s = [NSString stringWithUTF8String:utf8 ?: ""];
  if (!s.length) return;
  SRHIDOnMain(^{
    uint32_t savedMods = gModsDown;
    __block NSMutableString *pending = [NSMutableString string]; // non-ASCII run, inserted as one string
    void (^flush)(void) = ^{ if (pending.length) { SRHIDInsertTextMain([pending copy]); [pending setString:@""]; } };
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
      uint32_t usage; bool shift;
      if (ch.length == 1 && SRHIDAsciiToUsage([ch characterAtIndex:0], &usage, &shift)) {
        flush();
        SRHIDSyncModifiersMain(shift ? (1u << 17) : 0);
        SRHIDKeyUsageMain(usage, true);
        SRHIDKeyUsageMain(usage, false);
      } else [pending appendString:ch];
    }];
    flush();
    SRHIDSyncModifiersMain(savedMods);
  });
}

// ---------------------------------------------------------------- hardware keyboard availability
// UIKit decides "hardware keyboard attached" (=> no software keyboard, UIKeyboardImpl in hardware-keyboard mode) from
// GSEventIsHardwareKeyboardAttached(), which reads notifyd state that backboardd sets (GSEventSetHardwareKeyboardAttached).
// There is no notifyd/backboardd here, so interpose it (cross-image call from UIKitCore). Default: attached, since the
// host Mac keyboard is the input device. HID_SOFTWARE_KEYBOARD=1 -> report detached (software keyboard shows).
extern Boolean GSEventIsHardwareKeyboardAttached(void);
static Boolean gHWKeyboard = 1;
static Boolean my_GSEventIsHardwareKeyboardAttached(void) { return gHWKeyboard; }
__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } hid_interposers[] = {
  { (void *)my_GSEventIsHardwareKeyboardAttached, (void *)GSEventIsHardwareKeyboardAttached },
};

// ---------------------------------------------------------------- keyboard focus (event-deferring chain)
// UIKit only attaches the keyboard (UIKeyboardImpl delegate = first responder) once the scene "has keyboard focus":
// _UIKeyboardFocusAssistant asks a BKSHIDEventDeliveryPolicyObserver whether the scene's deferring token
// (FBSScene.ui_eventDeferringToken) is the final target of the keyboardFocus deferring chain. backboardd computes
// those chains and pushes them over the hid-services BSService (BKHIDEventDeliveryObserver) by calling the client
// method -[BKSHIDEventObserver didUpdateDeferringChains:withReply:]. We are backboardd here: call it in-process with
// one chain per environment (keyboardFocus, system) on the builtin display: [this pid / scene token], end of chain.
@interface NSObject (SRHIDDeferring)
+ (id)sharedInstance;
+ (id)keyboardFocusEnvironment;
+ (id)systemEnvironment;
+ (id)builtinDisplay;
- (id)initWithDisplay:(id)d environment:(id)e;
- (id)initWithPID:(int)pid token:(id)t;
- (id)initWithIdentity:(id)i compatibilityDisplay:(id)cd selectionPath:(id)sp path:(NSArray *)p modalities:(id)m constraints:(id)c
        containsSubset:(BOOL)sub containsEndOfChain:(BOOL)end finalStringTargetIndex:(long long)idx generation:(unsigned long long)gen;
- (void)didUpdateDeferringChains:(NSArray *)chains withReply:(id)reply;
- (id)_FBSScene;
- (id)ui_eventDeferringToken;
@end
static unsigned long long gChainGeneration = 1;
static id gLastFocusToken;
static void SRHIDPushDeferringChains(void) {
  UIWindowScene *ws = SRHIDScene();
  id token = [[ws _FBSScene] ui_eventDeferringToken];
  if (!token) { VLOG("no scene deferring token yet"); return; }
  if ([token isEqual:gLastFocusToken]) return;
  gLastFocusToken = token;
  id disp = [NSClassFromString(@"BKSHIDEventDisplay") builtinDisplay];
  Class EnvC = NSClassFromString(@"BKSHIDEventDeferringEnvironment");
  NSMutableArray *chains = [NSMutableArray array];
  for (id env in @[[EnvC keyboardFocusEnvironment], [EnvC systemEnvironment]]) {
    id ident = [[NSClassFromString(@"BKSEventDeferringChainIdentity") alloc] initWithDisplay:disp environment:env];
    id target = [[NSClassFromString(@"BKSHIDEventDeferringTarget") alloc] initWithPID:getpid() token:token];
    id chain = [[NSClassFromString(@"BKSHIDEventDeliveryChain") alloc] initWithIdentity:ident compatibilityDisplay:nil selectionPath:nil
        path:@[target] modalities:nil constraints:nil containsSubset:NO containsEndOfChain:YES finalStringTargetIndex:0 generation:gChainGeneration++];
    if (chain) [chains addObject:chain];
  }
  LOG("keyboard focus: deferring chains -> scene token %s", [[token description] UTF8String]);
  [[NSClassFromString(@"BKSHIDEventObserver") sharedInstance] didUpdateDeferringChains:chains withReply:nil];
}

// ---------------------------------------------------------------- dictation livelock workaround
// When a text field becomes first responder, the keyboard dock asks whether dictation is available
// (-[UIDictationConnection dictationIsAvailableForLanguage:] -> AssistantServices). Without assistantd every query makes
// AFDictationConnection report "availability changed" again -> UISystemKeyboardDockController re-queries -> ... : the
// main queue livelocks (thousands of "AFPreferences _languageCodeWithFallback" logs/s) and no further input is handled.
// Report dictation as unavailable without touching AssistantServices. HID_KEEP_DICTATION=1 disables this.
static BOOL sr_no(id self, SEL _cmd, ...) { return NO; }
static void SRHIDDisableDictation(void) {
  Class conn = NSClassFromString(@"UIDictationConnection"), ctl = NSClassFromString(@"UIDictationController");
  Method m;
  if ((m = class_getInstanceMethod(conn, NSSelectorFromString(@"dictationIsAvailableForLanguage:")))) method_setImplementation(m, (IMP)sr_no);
  if ((m = class_getClassMethod(ctl, NSSelectorFromString(@"dictationIsFunctional")))) method_setImplementation(m, (IMP)sr_no);
  if ((m = class_getInstanceMethod(conn, NSSelectorFromString(@"dictationConnnectionDidChangeAvailability:")))) method_setImplementation(m, (IMP)sr_no);
}

// ---------------------------------------------------------------- remote keyboard arbiter
// _UIRemoteKeyboards is the client of SpringBoard's keyboard arbiter (com.apple.UIKit.KeyboardManagement.hosted).
// Without SpringBoard its connection fails and -queue_failedConnection: "hands the keyboard away" (a keyboard-down
// change, isLocalEvent) => the focused text field immediately resigns first responder (and it retries every 10 s).
// Swallow the failure: the arbiter proxy stays unusable (calls fail softly), the keyboard stays with this process.
// (Turning +[_UIRemoteKeyboards enabled] off instead makes UIKit host the keyboard in a local FrontBoard scene, which
// asserts in FBWorkspaceEventDispatcher.) HID_KEEP_REMOTE_KEYBOARDS=1 disables this.
static void sr_void(id self, SEL _cmd, ...) {}
static void SRHIDNeutralizeRemoteKeyboards(void) {
  Method m = class_getInstanceMethod(NSClassFromString(@"_UIRemoteKeyboards"), NSSelectorFromString(@"queue_failedConnection:"));
  if (m) method_setImplementation(m, (IMP)sr_void);
}

// ---------------------------------------------------------------- viewer protocol receiver (viewer/protocol.h)
static mach_port_t gRecvPort;
static void SRHIDHandleInput(const sr_input_msg_t *m) {
  switch (m->kind) {
    case SR_IN_TOUCH_BEGAN: SRHIDTouch(SRHID_TOUCH_BEGAN, m->x, m->y); break;
    case SR_IN_TOUCH_MOVED: SRHIDTouch(SRHID_TOUCH_MOVED, m->x, m->y); break;
    case SR_IN_TOUCH_ENDED: SRHIDTouch(SRHID_TOUCH_ENDED, m->x, m->y); break;
    case SR_IN_KEY_DOWN:
    case SR_IN_KEY_UP: SRHIDKeyMac((uint16_t)m->keycode, m->kind == SR_IN_KEY_DOWN, m->modifiers); break;
    case SR_IN_TEXT: { char t[sizeof m->text + 1]; memcpy(t, m->text, sizeof m->text); t[sizeof m->text] = 0; SRHIDText(t); break; }
    case 8 /* proposed SR_IN_SCROLL: x,y = cursor (scene pt); dx,dy = two floats in text[0..7] */: {
      float d[2]; memcpy(d, m->text, sizeof d); SRHIDScroll(m->x, m->y, d[0], d[1]); break;
    }
    case SR_IN_RESIZE: {
      // scenes.dylib (if loaded): resize the scene to the host view size in points
      void (*upd)(double, double, BOOL, long) = dlsym(RTLD_DEFAULT, "SRScenesUpdate");
      if (upd && m->x > 0 && m->y > 0) upd(m->x, m->y, YES, 1);
      break;
    }
    default: VLOG("unknown input kind %u", m->kind);
  }
}
void SRHIDStartReceiver(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_port_array_t ports = NULL; mach_msg_type_number_t n = 0;
    mach_port_t host = MACH_PORT_NULL;
    if (mach_ports_lookup(mach_task_self(), &ports, &n) == KERN_SUCCESS && n > SR_PORT_SLOT_HOST) host = ports[SR_PORT_SLOT_HOST];
    if (!MACH_PORT_VALID(host)) { VLOG("no host port: viewer receiver not started"); return; }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gRecvPort);
    mach_port_insert_right(mach_task_self(), gRecvPort, gRecvPort, MACH_MSG_TYPE_MAKE_SEND);
    dispatch_queue_t q = dispatch_queue_create("dev.simrun.hid.receiver", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gRecvPort, 0, q);
    dispatch_source_set_event_handler(src, ^{
      union { mach_msg_header_t h; sr_input_msg_t in; char buf[sizeof(sr_input_msg_t) + 256]; } m;
      while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, gRecvPort, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
        if (m.h.msgh_id == SR_MSG_INPUT && m.h.msgh_size >= sizeof(sr_input_msg_t)) {
          VLOG("viewer input kind=%u (%.1f,%.1f) key=0x%x mods=0x%x", m.in.kind, m.in.x, m.in.y, m.in.keycode, m.in.modifiers);
          SRHIDHandleInput(&m.in);
        } else mach_msg_destroy(&m.h);
      }
    });
    dispatch_resume(src);
    (void)CFBridgingRetain(src);
    sr_port_msg_t h = {0};
    h.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    h.h.msgh_size = sizeof h; h.h.msgh_remote_port = host; h.h.msgh_id = SR_MSG_HELLO;
    h.b.msgh_descriptor_count = 1;
    h.port.name = gRecvPort; h.port.disposition = MACH_MSG_TYPE_MAKE_SEND; h.port.type = MACH_MSG_PORT_DESCRIPTOR;
    kern_return_t kr = mach_msg(&h.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof h, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    LOG("viewer input receiver (pid %d %s) on port 0x%x, SR_MSG_HELLO kr=0x%x", getpid(), getprogname(), gRecvPort, kr);
  });
}

// ---------------------------------------------------------------- scripted input (testing)
// HID_SCRIPT="wait 1; tap 201 105; drag 201 700 201 300 [steps] [seconds]; text hello; key 0x28; mac 0x7d [mods]; view <accessibilityId>"
//   tap X Y | drag X0 Y0 X1 Y1 [steps=20] [secs=0.3] | pinch CX CY R0 R1 | text STRING | key USAGE | mac KEYCODE [MODS] | wait SECS
//   tapid ID (tap the center of the view with that accessibilityIdentifier)
static UIView *SRHIDFindView(UIView *v, NSString *ident) {
  if ([v.accessibilityIdentifier isEqualToString:ident]) return v;
  for (UIView *s in v.subviews) { UIView *r = SRHIDFindView(s, ident); if (r) return r; }
  return nil;
}
static void SRHIDRunScript(NSArray<NSString *> *cmds, NSUInteger i) {
  if (i >= cmds.count) { LOG("script done"); return; }
  NSArray<NSString *> *a = [[cmds[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "];
  NSString *op = a.firstObject; double next = 0.3;
  #define ARG(k) ((a.count > (k)) ? a[k].doubleValue : 0)
  if (op.length) LOG("script: %s", cmds[i].UTF8String);
  if ([op isEqual:@"wait"]) next = ARG(1);
  else if ([op isEqual:@"tap"] || [op isEqual:@"tapid"]) {
    float x = ARG(1), y = ARG(2);
    if ([op isEqual:@"tapid"]) {
      UIWindowScene *ws = SRHIDScene(); UIView *v = nil;
      for (UIWindow *w in ws.windows) if ((v = SRHIDFindView(w, a[1]))) break;
      if (!v) { LOG("no view with id %s", a[1].UTF8String); }
      CGPoint c = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toCoordinateSpace:ws.coordinateSpace];
      x = c.x; y = c.y;
    }
    SRHIDTouch(SRHID_TOUCH_BEGAN, x, y);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ SRHIDTouch(SRHID_TOUCH_ENDED, x, y); });
  } else if ([op isEqual:@"drag"]) {
    float x0 = ARG(1), y0 = ARG(2), x1 = ARG(3), y1 = ARG(4); int steps = a.count > 5 ? (int)ARG(5) : 20; double secs = a.count > 6 ? ARG(6) : 0.3;
    SRHIDTouch(SRHID_TOUCH_BEGAN, x0, y0);
    for (int s = 1; s <= steps; s++) {
      float t = (float)s / steps;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SRHIDTouch(SRHID_TOUCH_MOVED, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t);
        if (s == steps) SRHIDTouch(SRHID_TOUCH_ENDED, x1, y1);
      });
    }
    next = secs + 0.3;
  } else if ([op isEqual:@"pinch"]) {
    float cx = ARG(1), cy = ARG(2), r0 = ARG(3), r1 = ARG(4); int steps = 20; double secs = 0.4;
    SRHIDTouchFinger(0, SRHID_TOUCH_BEGAN, cx - r0, cy); SRHIDTouchFinger(1, SRHID_TOUCH_BEGAN, cx + r0, cy);
    for (int s = 1; s <= steps; s++) {
      float r = r0 + (r1 - r0) * s / steps;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * s / steps * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SRHIDTouchFinger(0, SRHID_TOUCH_MOVED, cx - r, cy); SRHIDTouchFinger(1, SRHID_TOUCH_MOVED, cx + r, cy);
        if (s == steps) { SRHIDTouchFinger(0, SRHID_TOUCH_ENDED, cx - r, cy); SRHIDTouchFinger(1, SRHID_TOUCH_ENDED, cx + r, cy); }
      });
    }
    next = secs + 0.3;
  } else if ([op isEqual:@"wheel"]) {   // wheel X Y DY [N]: N wheel ticks of DY points, 16 ms apart
    float x = ARG(1), y = ARG(2), dy = ARG(3); int n = a.count > 4 ? (int)ARG(4) : 10;
    for (int k = 0; k < n; k++)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)k * 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ SRHIDScroll(x, y, 0, dy); });
    next = n * 0.016 + 0.5;
  } else if ([op isEqual:@"text"]) {
    NSString *t = [[a subarrayWithRange:NSMakeRange(1, a.count - 1)] componentsJoinedByString:@" "];
    SRHIDText(t.UTF8String);
  } else if ([op isEqual:@"key"]) {
    uint32_t u = (uint32_t)strtoul(a[1].UTF8String, NULL, 0);
    SRHIDKeyUsage(u, true); SRHIDKeyUsage(u, false);
  } else if ([op isEqual:@"mac"]) {
    uint16_t k = (uint16_t)strtoul(a[1].UTF8String, NULL, 0); uint32_t mods = a.count > 2 ? (uint32_t)strtoul(a[2].UTF8String, NULL, 0) : 0;
    SRHIDKeyMac(k, true, mods); SRHIDKeyMac(k, false, mods); SRHIDReleaseModifiers();
  } else if ([op isEqual:@"scene"]) {   // scene W H ORIENT (scenes.dylib SRScenesUpdate)
    void (*upd)(double, double, BOOL, long) = dlsym(RTLD_DEFAULT, "SRScenesUpdate");
    if (upd) upd(ARG(1), ARG(2), YES, (long)ARG(3)); else LOG("no SRScenesUpdate");
    next = 1.0;
  } else if ([op isEqual:@"where"]) {   // where ID: log the view's center in scene coordinates
    UIWindowScene *ws = SRHIDScene(); UIView *v = nil;
    for (UIWindow *w in ws.windows) if ((v = SRHIDFindView(w, a[1]))) break;
    CGPoint c = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toCoordinateSpace:ws.coordinateSpace];
    LOG("where %s: (%.1f,%.1f) scene bounds %s orient %ld", a[1].UTF8String, c.x, c.y, NSStringFromCGRect(ws.coordinateSpace.bounds).UTF8String, (long)ws.effectiveGeometry.interfaceOrientation);
  } else if ([op isEqual:@"dump"]) {
    id kb = [NSClassFromString(@"UIKeyboardImpl") activeInstance];
    id fr = [SRHIDScene().keyWindow firstResponder];
    LOG("dump: keyboardImpl=%p hwMode=%d delegate=%s firstResponder=%s", (__bridge void *)kb,
        kb ? ((BOOL (*)(id, SEL))objc_msgSend)(kb, NSSelectorFromString(@"isInHardwareKeyboardMode")) : -1,
        [[[[kb valueForKey:@"inputDelegateManager"] valueForKey:@"keyInputDelegate"] description] UTF8String], [[fr description] UTF8String]);
  } else if (op.length) LOG("unknown script op %s", op.UTF8String);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(next * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SRHIDRunScript(cmds, i + 1); });
}

static NSString *const kDemoScript =
  @"wait 1; tap 201 105; wait 0.5; "                                  // UIButton (touchUpInside action)
   "drag 201 800 201 400 20 0.3; wait 2.5; "                           // UITableView pan + deceleration
   "tap 30 300; wait 0.5; "                                            // table row selection
   "tapid switch; wait 0.5; "                                          // UISwitch
   "tapid field; wait 3; "                                             // UITextField focus (first focus loads keyboard: slow)
   "text hello; wait 0.3; text , World!; wait 0.3; key 0x2A; wait 0.3; " // typing, shift, backspace
   "mac 0x7b; mac 0x7b; text X; wait 0.3; "                            // left arrow x2 (mac keycodes) then insert
   "mac 0x00 0x100000; text Z; wait 0.3; "                             // cmd-A (select all) then type over it
   "text ü→; wait 0.3; "                                               // non-ASCII via insertText
   "key 0x28; wait 0.5; "                                              // Return -> textFieldShouldReturn
   "mac 0x7d; wait 0.2; mac 0x28 0x100000; wait 0.3; "                 // down arrow + cmd-K key commands
   "pinch 201 600 40 120; wait 0.5; "                                 // two-finger pinch (multitouch)
   "wheel 201 700 -10 25";                                             // emulated scroll wheel (no fling)

__attribute__((constructor)) static void hid_init(void) {
  gVerbose = getenv("HID_VERBOSE") != NULL;
  if (getenv("HID_SOFTWARE_KEYBOARD")) gHWKeyboard = 0;
  if (getenv("HID_KB_SOURCE")) kKeyboardSource = atoi(getenv("HID_KB_SOURCE"));
  // DYLD_INSERT_LIBRARIES is inherited by helper processes (e.g. MTLCompilerService): only act inside an .app
  if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) return;
  if (!getenv("HID_KEEP_DICTATION")) SRHIDDisableDictation();
  if (!getenv("HID_KEEP_REMOTE_KEYBOARDS")) SRHIDNeutralizeRemoteKeyboards();
  if (!getenv("HID_NO_RECEIVER")) SRHIDStartReceiver();
  if (!getenv("HID_NO_FOCUS")) {
    for (NSNotificationName n in @[UISceneDidActivateNotification, UIWindowDidBecomeKeyNotification])
      [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        SRHIDPushDeferringChains();
      }];
  }
  NSString *script = getenv("HID_SCRIPT") ? @(getenv("HID_SCRIPT")) : getenv("HID_DEMO") ? kDemoScript : nil;
  if (script) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
      static int once; if (once++) return;
      SRHIDRunScript([script componentsSeparatedByString:@";"], 0);
    }];
  }
}
