# hid/ — touch and keyboard input without backboardd

**Status: working.** `hid.dylib` makes UIKit deliver real input in a sim app process that has no backboardd or
SpringBoard. All of the following were verified:
- UIButton `touchUpInside` actions, UISwitch, UITapGestureRecognizer, UITableView row selection.
- UIScrollView/UITableView panning, deceleration and tap-to-stop.
- Two-finger pinch (UIPinchGestureRecognizer).
- Typing into UITextField: shift, backspace, arrows, cmd-A, Return/`textFieldShouldReturn`, non-ASCII text.
- `pressesBegan`/UIKey, UIKeyCommand (arrow keys, cmd-K).
- SwiftUI: Stepper, TextField, NavigationLink push, interactive edge-swipe back.
- Landscape scenes.

It works in a plain null-bootstrap process (`run.sh` with `HID_PLAIN=1`) and on the full stack (`../simapp.sh`), end to
end from the AppKit viewer.

```
./build.sh              # HIDTest.app (app.m) + hid.dylib (hid.m)
./run.sh [App]          # full stack (../simapp.sh + hid.dylib), runs the built-in demo script, prints [app]/[hid] lines,
                        # writes last_run.log + last_run.png. Output: sample_output.txt
HID_SCRIPT="wait 1; tap 201 486" ./run.sh ../../sim2mac/Hello.app     # any app, scripted
HID_PLAIN=1 HID_SCRIPT="wait 1; tap 201 105" ./run.sh                    # plain process (scenes.dylib only)
./viewer_demo.sh        # through the viewer: host mouse/key events -> viewer.m -> SR_IN_* -> hid.dylib -> UIKit
                        # (SUI.app + Hello.app; writes viewer_*.png; uses CGEventPost: moves the real cursor and needs
                        # the Accessibility permission for the terminal)
```

Proof screenshots:
- `viewer_sui_1.png`: Count 3 after three clicks on "+", and "hello SwiftUI" typed.
- `viewer_sui_2.png`: backspace, left arrow and "-" give "hello Swi-ft".
- `viewer_sui_3.png`: NavigationLink pushed (Detail 2).
- `viewer_sui_4.png`: edge-swipe back.
- `viewer_hello.png`: "Tapped at …".
- `landscape_input.png`: landscape-scene run.

## 1. How a sim app receives HID events (iOS 27.1 sim UIKit, verified in IDA and at runtime)

```
backboardd ──(mach, BKSHIDEventRegisterEventCallbackOnQueue port)──► _UIEventFetcherReceiveHIDEventCallback
-[UIApplication _enqueueHIDEvent:]  ==  [UIApp->_eventFetcher _receiveHIDEvent:]   (async onto "com.apple.uikit.eventfetch")
   └► -[UIEventFetcher ingestHIDEvent:] -> filter chain (_receiveBlock: hover memory, drag extraction, edge-swipe discard,
      wake-on-touch sync, _UIHIDTransformer (iOSMac), pencil...) -> addFilteredHIDEvent: -> eventFetcherDidReceiveEvents:
      -> UIEventDispatcher signals a main-runloop source
   └► main thread: __dispatchPreprocessedEventFromEventQueue
        -[UIEventEnvironment UIKitEventForHIDEvent:]
           digitizer (type 11)  -> UITouchesEvent of _UIEventHIDUIWindowForHIDEvent(e)'s scene
           keyboard  (type 3)   -> UIPhysicalKeyboardEvent (-_physicalKeyboardEventForHIDEvent:)
        _UIEventHIDUIWindowForHIDEvent(e) = +[UIWindow _windowWithContextId: BKSHIDEventGetBaseAttributes(e).contextID]
        touches: _UIEventHIDEnumerateChildren -> UITouch per finger child (identity/index), hit-test in that window,
                 -[UIApplication sendEvent:] -> UIWindow -> UIGestureEnvironment (gesture recognizers) + touches*
        keys:    -[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:] -> handleKeyUIEvent: -> UIPressesEvent through the
                 responder chain (pressesBegan) -> unhandled presses end at -[UIApplication pressesBegan:withEvent:]
                 (_UIPressesContainsExternalKeyboardSource) -> _handleKeyboardPressEvent: -> UIKeyboardImpl handleKeyEvent:
                 -> _UIKeyboardStateManager handleKeyEvent:executionContext: -> handleKeyWithString: -> insertText on
                 inputDelegateManager.keyInputDelegate (the focused text input)
```
BKS attributes travel in the IOHIDEvent attribute data (`BKSHIDEventSetAttributes` / `BKSHIDEventGet*Attributes`,
cached as the attachment "backboardd-attr-cache-21000331"):
- `BKSHIDEventDigitizerAttributes` holds the token (CAContext id), the display, `systemGesturesPossible`,
  `systemGestureStateChange` and per-path attributes.
- `BKSHIDEventBaseAttributes` holds the token/contextID, environment, display, source and options.

## 2. Injection point: `-[UIApplication _enqueueHIDEvent:]` with backboardd-shaped IOHIDEvents

**Why this point.** It is the exact entry point of backboardd-delivered events. The whole UIKit pipeline runs for
real: the fetcher filter chain, UITouch creation and tracking, gesture environment, the UIScrollView pan physics, press
and key-command handling, and the text-input system. SwiftUI works unchanged.

**Alternatives considered:**
- **KIF/EarlGrey-style UITouch + UIEvent synthesis.** It bypasses the fetcher and gesture environment. It is fragile
  against SwiftUI and the new Gestures framework, and it does nothing for keyboard input.
- **XCTest `XCSynthesizedEventRecord`.** It goes through testmanagerd → backboardd's `IOHIDEventSystem`, so it needs
  the daemons.
- **A complete in-process BKHIDEventDeliveryManager BSService** (BSXPC over the anonymous listener). It is not needed
  for delivery, because the app only consumes events from its fetcher. Only the focus *observation* half was needed,
  and §4 delivers that message in-process.

### Touch events (`SRHIDTouchFinger`)
One IOHIDEvent per change, shaped like backboardd's:

| Field | Value |
|---|---|
| parent | `IOHIDEventCreateDigitizerEvent(type = 3 Hand, index 0, identity 0, mask, x, y, range = touch = anyFingerStillDown)` with `kIOHIDEventFieldDigitizerIsDisplayIntegrated` = 1 |
| children | one `IOHIDEventCreateDigitizerFingerEvent(index = finger+1, identity = unique per touch, mask, x, y, pressure 1/0, range = touch)` for **every finger currently down**. Major and minor radius are 5 |
| event mask | began/ended: Range\|Touch\|Identity (0x23). moved: Position (0x4). cancelled: \|Cancel (0x80). Unchanged fingers: 0 |
| sender ID | a fixed fake (UIKit migrates touch maps per sender) |
| BKS | `BKSHIDEventSetDigitizerInfo(e, contextID, systemGesturesPossible = NO, stateChange = NO, display = NULL, 0, 0)` |
| contextID | `-[UIWindow _contextId]` of the topmost visible window in the active UIWindowScene whose `-hitTest:` hits at touch-down. This replaces backboardd's `contextIdAtPosition`. It is fixed for the whole touch, and all fingers share it |
| coordinates | **scene points** (UIWindowScene coordinate space, top left). Verified in portrait and in a landscape scene rotated by `SRScenesUpdate(…, orientation 3)`: (600,300) lands at view (600,300) |
| timestamp | `mach_absolute_time()`. Velocity and deceleration work |

### Keyboard events (`SRHIDKeyUsage`)
- `IOHIDEventCreateKeyboardEvent(page 7, usage, down)` plus a fixed sender ID.
- `BKSHIDEventSetSimpleInfo(e, source = 1 externalKeyboard, 0, NULL, contextID = key window's _contextId, NO)`. Without
  a contextID, `_UIEventHIDUIWindowForHIDEvent` returns nil and **UIKit silently drops the event**.
- Modifiers are real key events (0xE0–0xE7), as from a real keyboard. GSKeyboard tracks the modifier state from them.

## 3. Keyboard and text input: what else UIKit needs from backboardd and SpringBoard

Each item below was found by tracing why typed keys arrived as `pressesBegan` but never reached the text field.

| # | Missing piece | Symptom | Fix in hid.dylib |
|---|---|---|---|
| 1 | `GSEventIsHardwareKeyboardAttached()` reads notifyd state that backboardd sets | software-keyboard mode. On first focus, the keyboard dock runs the dictation livelock (#4) | `__interpose` → YES. `HID_SOFTWARE_KEYBOARD=1` reports detached: typing still works, but no on-screen keyboard is drawn, see §6 |
| 2 | **Keyboard focus.** `_UIKeyboardFocusAssistant` attaches the keyboard (`UIKeyboardImpl` delegate = first responder) only if a `BKSHIDEventDeliveryPolicyObserver` reports that the scene's `FBSScene.ui_eventDeferringToken` is the final target of the keyboardFocus deferring chain. backboardd pushes the chains over the hid-services BSService by calling the client method `-[BKSHIDEventObserver didUpdateDeferringChains:withReply:]` | `keyInputDelegate == nil`. Keys reach `_UIKeyboardStateManager handleKeyEvent:executionContext:` and are dropped | On scene activation or key-window change we call that method in-process on `+[BKSHIDEventObserver sharedInstance]`. There is one `BKSHIDEventDeliveryChain` per environment (keyboardFocus, system), with identity `BKSEventDeferringChainIdentity(builtinDisplay, env)` and path `[BKSHIDEventDeferringTarget(getpid(), sceneToken)]`, `containsEndOfChain` YES and `finalStringTargetIndex` 0. Disable with `HID_NO_FOCUS=1`, which stops typing |
| 3 | `_UIRemoteKeyboards` (SpringBoard's keyboard arbiter `com.apple.UIKit.KeyboardManagement.hosted`) connection fails → `-queue_failedConnection:` posts a "keyboard down" change | the focused text field resigns first responder about 100 ms after focus | Swizzle `-queue_failedConnection:` to a no-op. Setting `+[_UIRemoteKeyboards enabled]` = NO was tried and makes UIKit host the keyboard in a local FrontBoard scene, which asserts in `FBWorkspaceEventDispatcher` (invalid pid). `HID_KEEP_REMOTE_KEYBOARDS=1` turns the fix off |
| 4 | AssistantServices dictation without assistantd: every `dictationIsAvailableForLanguage:` query triggers `_tellSpeechDelegateAvailabilityChanged`, and `UISystemKeyboardDockController` queries again | **main-thread livelock** on first text focus (thousands of "AFPreferences _languageCodeWithFallback" lines per second) | `-[UIDictationConnection dictationIsAvailableForLanguage:]`, `+[UIDictationController dictationIsFunctional]` and `-[UIDictationConnection dictationConnnectionDidChangeAvailability:]` → NO / no-op. `HID_KEEP_DICTATION=1` turns this off |

Notes:
- The **first** text focus loads `UIKBAutofillController` → `AFUITargetDetectionController` (a soft-linked dlopen of
  a large framework tree), which blocks the main thread for about 2–3 s. Keys typed during that time are lost, so the
  demo waits 3 s. Later focuses are instant.
- "failed to fetch device property for senderID" (`getKeyboardDevicePropertiesForSenderID`, a BKSHIDKeyboard call to
  backboardd) is logged per key and is harmless. UIKit falls back to the default US layout.

### Key mapping
- `SRHIDKeyMac(keyCode, down, NSEventModifierFlags)` maps kVK_* to HID usages with a full ANSI/ISO/JIS table: letters,
  digits, punctuation, Return/Tab/Space/Delete/Escape, F1–F20, the keypad, Home/End/PgUp/PgDn/ForwardDelete, arrows,
  modifiers and Eisu/Kana.
- Before each non-modifier key, the synthesized shift/control/option/command keys are pressed or released to match the
  flags. This is needed because the viewer sends no `flagsChanged:`. Caps lock (0x39) is ignored.
- Mapping is **positional**, like Simulator.app's hardware keyboard: UIKit translates with its own HW layout (US by
  default), so a non-US host layout produces US characters.
- `SRHIDText(utf8)`:
  - US-ASCII characters become key down/up pairs, with shift where needed. They behave like real keys: they appear as
    `pressesBegan` and go through `shouldChangeCharactersInRange:`.
  - Every other composed character is collected and inserted with `[UIKeyboardImpl activeInstance] insertText:`, the
    path the software keyboard or an IME commit takes. The fallback is the first responder's `UIKeyInput insertText:`.
    This path fires `editingChanged` but not `shouldChangeCharacters`.

## 4. API (hid.h) and the viewer receiver

```c
void SRHIDTouch(int phase, float x, float y);                    // finger 0; SRHID_TOUCH_BEGAN/MOVED/ENDED/CANCELLED = 1..4
void SRHIDTouchFinger(int finger, int phase, float x, float y);  // multitouch, finger 0..9 (9 is used by SRHIDScroll)
bool SRHIDDetachTouches(SRHIDDetachedTouchHandler h, void *ctx); // drag began: cancel the app's touches, send their
                                                                 // moves/lift to h (drag.dylib, docs/dragdrop.md)
void SRHIDDragEvent(uint32_t session, int locus, float x, float y, bool touching); // a drag HID event
void SRHIDScroll(float x, float y, float dx, float dy);          // wheel/trackpad, emulated (see §6)
void SRHIDKeyUsage(uint32_t hidUsage, bool down);                // USB HID page 7
void SRHIDKeyMac(uint16_t macKeyCode, bool down, uint32_t macModifierFlags);
void SRHIDReleaseModifiers(void);
void SRHIDText(const char *utf8);
void SRHIDStartReceiver(void);                                   // automatic in the constructor
```
- All functions are thread-safe. They run on the main thread, asynchronously when called from elsewhere, in call
  order. Coordinates are scene points.
- **Receiver:** the constructor (only in processes whose main bundle is a `.app`, see §5) allocates a receive port. It
  sends `SR_MSG_HELLO` {port} to `mach_ports_lookup()[SR_PORT_SLOT_HOST]` and serves `SR_MSG_INPUT` on a serial dispatch
  queue:
  - `SR_IN_TOUCH_*` → `SRHIDTouch`
  - `SR_IN_KEY_DOWN/UP` → `SRHIDKeyMac(keycode, modifiers)`. The characters field is not used, because keys are
    positional.
  - `SR_IN_TEXT` → `SRHIDText`
  - `SR_IN_RESIZE` → `SRScenesUpdate(x, y, YES, portrait)` via dlsym, if scenes.dylib is loaded
  - kind 8 (proposed `SR_IN_SCROLL`, below) → `SRHIDScroll`
- No viewer change is needed for touches or keys; this was tested. Disable the receiver with `HID_NO_RECEIVER=1`.
- **Testing hooks:**
  - `HID_SCRIPT="wait S; tap X Y; tapid ACCESSIBILITY_ID; drag X0 Y0 X1 Y1 [steps] [secs]; pinch CX CY R0 R1; wheel X Y DY [n]; text STR; key USAGE; mac KEYCODE [FLAGS]; scene W H ORIENT; where ID; dump"`
    runs after the first scene activation.
  - `HID_DEMO=1` runs the HIDTest script.
  - `HID_VERBOSE=1` logs every injected event.

## 5. Merge instructions (for the integrator)

- **Drop-in:** append `hid.dylib` to the insert list. `SIMAPP_EXTRA_INSERT=$B/hid/hid.dylib ./simapp.sh App.app`
  already works.
- **To fold it into the stack permanently:** add it to `SIMNS_INSERT` in simapp.sh, or compile hid.m into glue.dylib.
  It has no dependency on other dylibs: it uses `SRScenesUpdate` only optionally via dlsym, and it includes
  `../viewer/protocol.h`.
- **Interposers:** only one, `GSEventIsHardwareKeyboardAttached`. No other SimRun dylib interposes it (checked rshim,
  glue, scenes). Everything else is ObjC swizzling with `method_setImplementation`:
  - `UIDictationConnection` ×2, `UIDictationController` ×1
  - `_UIRemoteKeyboards -queue_failedConnection:`

  None of these overlap with scenes.dylib, which swizzles BSServiceConnectionEndpoint, CADisplay and CAContext.
- **scenes.dylib needs no change.** Its hid-services "sink" endpoint must stay: BKSHIDEventDeliveryManager and
  BKSHIDEventObserver need a live connection or they assert or exit. The keyboard-focus chains are pushed directly to
  the client object, so nothing has to be answered on the sink.
- **Heads-up (applies to every injected dylib):** `DYLD_INSERT_LIBRARIES` leaks into helper processes the app spawns,
  for example **MTLCompilerService**. hid.dylib loaded there once and sent its own SR_MSG_HELLO, which stole the
  viewer's input port.
  - hid.dylib now returns early unless the main bundle is an `.app`.
  - rshim, glue and scenes are injected into MTLCompilerService too; it is worth checking that they behave.
  - Better long term: strip `DYLD_INSERT_LIBRARIES` from the environment in an injected `posix_spawn` hook, or have
    simns pass it only to the app.
- **Proposed protocol extension** (viewer/protocol.h + viewer.m are not mine, so they are not edited):
  - `SR_IN_SCROLL = 8`: x,y = cursor in scene points, and `float dx, dy` memcpy'd into `text[0..7]`. In
    `-scrollWheel:`, send `e.scrollingDeltaX/Y` (natural direction; drop `e.momentumPhase` events or keep them for
    momentum). hid.dylib already handles kind 8.
  - Optionally `-magnifyWithEvent:` → two-finger pinch via `SRHIDTouchFinger` (would need a new message kind).

## 6. Open issues

- **Multitouch from the host:** fully supported by the API (`SRHIDTouchFinger`, verified with a pinch). The viewer only
  produces one finger. Mapping trackpad magnify/rotate gestures to two synthetic fingers around the cursor is easy
  once the viewer forwards them.
- **Scroll wheel / trackpad:** iPhone-idiom UIKit has no pointer, so `SRHIDScroll` emulates scrolling with a dedicated
  virtual finger. The finger follows the accumulated deltas and lifts 120 ms after the last delta, after a few
  near-still samples so UIScrollView does not fling. Verified: 25 ticks of 10 pt scroll 240 pt with `decelerate=0`.
  - Limitations: content is grabbed at the cursor, so a button under it can get highlighted or cancelled, and
    horizontal plus vertical is a single drag.
  - A real UIScrollEvent path would use pointer events (IOHIDEvent pointer with scroll child +
    BKSHIDEventPointerAttributes, `_UIEventHIDGetChildScrollEvent` → UIScrollEvent). That is iPad / pointer-only and
    not done.
- **Pointer / hover:** not implemented. Hover (UIHoverGestureRecognizer, iPad pointer effects) needs digitizer
  range-without-touch or pointer events with BKSHIDEventPointerAttributes, plus an iPad device profile.
- **Text input / IME:**
  - There is no marked-text (IME composition) bridge from the host. Committed host IME text can be sent with
    `SR_IN_TEXT` → `SRHIDText` (inserted, not composed).
  - The host keyboard layout is not mirrored, because the mapping is positional and US. Proper support would set the
    HW layout (`BKSHIDKeyboardSetLayout` / GSKeyboard) from the host's input source, or send characters for printable
    keys.
  - Caps lock is not mirrored.
  - Key repeat: we send one down/up per host event. Host autorepeat arrives as repeated keyDowns without keyUp, which
    UIKit accepts as repeats.
- **Software keyboard:** with `HID_SOFTWARE_KEYBOARD=1` typing works (`software_keyboard_mode.png`), but no on-screen
  keyboard is drawn. The keyboard window or scene is never hosted, because remote keyboard hosting needs SpringBoard.
  Touch typing on an on-screen keyboard would need that UI.
- **Event deferring:** UIKit's own deferring rules (sent to BKSHIDEventDeliveryManager) are swallowed by the sink. With
  one app scene, the chains we push are what backboardd would compute. Multiple scenes, remote view controllers, or
  focus moving between windows would need a real rule evaluator (an in-process BKHIDEventDeliveryManager BSService
  that answers `setObservesDeferringChanges:` and turns the rules into chains). Keyboard events always target the key
  window's context.
- **Touch routing across windows:** the window is picked with UIKit's own hit-test, not CA's
  `contextIdAtPosition`. That is equivalent for normal UIWindows. A render-server-based lookup is possible now
  (`[CAWindowServer server].displays[0]`) but is not needed.
- **Rotation:** input uses scene coordinates and works in landscape. The viewer must send rotated-space points when the
  scene is rotated (currently its view stays 402x874).
- **Plain mode (`HID_PLAIN=1`, no render server):** UIScrollView deceleration crashes in `+[CADisplayLink
  _displayLinkWithDisplay:…]` (nil CADisplay; scenes' no-render-server stopgap). This is not an input bug; it does not
  happen on the full stack.
- **Physical keyboard device properties / layout** (`BKSHIDKeyboardGetDeviceProperties`,
  `BKSHIDServicesGetHardwareKeyboardLanguage`) fail softly. They could be answered by the same future hid-services
  service.

## Files
- `hid.m` → `hid.dylib`, with `hid.h` (the API).
- `app.m` → `HIDTest.app`: a UIButton, UITextField with delegate logging, UISwitch, a 100-row UITableView, tap and
  pinch recognizers, touches/presses logging and UIKeyCommands. All of its logs carry the "[app]" prefix.
- `build.sh`, `run.sh` (scripted demo, full stack or `HID_PLAIN`), `sample_output.txt`, `last_run.png`.
- `hostinput.swift` (→ `hostinput`): a host-side event synthesizer for the viewer window. `viewer_demo.sh` and
  `viewer_*.png` are the end-to-end proof.
- `re/`: IDA decompilations (`uik_*.c`), made by `re/decre.py db out.c regex` with the idalib venv; `re/xsel.py` finds the callers of a selector.
  - UIKitCore: UIEventFetcher, `__dispatchPreprocessedEventFromEventQueue`, `UIKitEventForHIDEvent:`,
    `_handleKeyHIDEvent`, `_UIKeyboardStateManager handleKeyEvent:executionContext:`, `_UIKeyboardFocusAssistant`,
    `_UIRemoteKeyboards`.
  - BackBoardServices: `bbs_all.c`, covering `BKSHIDEventSetDigitizerInfo`, `BKSHIDEventSetSimpleInfo`,
    `BKSHIDEventObserver didUpdateDeferringChains:`, `_observationsFromChains:` and `BKSHIDEventDeliveryPolicyObserver`.
