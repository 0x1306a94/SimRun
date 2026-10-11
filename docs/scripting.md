# scripting — JavaScript inside a running app

**Status: working, early.** `simrun eval` runs a JavaScript script inside a running app, on its main thread. Scripts
can read the app's accessibility tree (UIKit's and SwiftUI's), tap and type through the same path as the window's
mouse and keyboard (hid.md), and call into Objective-C. It is meant for automating UI checks, and for coding agents
driving an app. The API is the spike's and will change: the plan is a Playwright-like one (see Next steps).

```bash
simrun eval Showcase 'ax.tree()'
simrun eval Showcase 'await tapOn("Keyboard"); await sleep(700); return ax.find("Jump")'
simrun eval Showcase -f flow.js       # or a script on stdin: simrun eval Showcase < flow.js
```

```js
// flow.js
await tapOn("Keyboard");                     // the first element whose label contains "Keyboard"
await sleep(700);
const field = ax.elements().find(e => e.traits.includes("textEntry"));
await tap(field.frame.x + field.frame.width / 2, field.frame.y + field.frame.height / 2);
await sleep(3000);                           // the first text focus blocks the main thread for ~3 s (hid.md)
type("hello from JS");
return ax.elements().find(e => e.traits.includes("textEntry")).value   // "hello from JS"
```

`simrun eval` prints the script's console output as it happens, then its value (strings as they are, anything else
as JSON); a thrown exception goes to stderr with where it was thrown, and the exit status is 1:

```
$ simrun eval Showcase 'function f() { throw new Error("deep") }
await sleep(10)
f()'
Error: deep
    at f (script.js:1:31)
    at script.js:3:2
```

## What a script is

- The body of an async function: `await` works at top level. A script that is one expression has that value; a longer
  one returns its value with `return` (`const x = 5; return x * 2`).
- It runs on the app's main thread, so it can touch UIKit directly. While it awaits, the app runs normally (taps get
  handled, animations play); a script that never awaits blocks the app until it ends.
- All scripts of an app share one JavaScript context: `globalThis.x = …` in one script is there in the next. Each
  script gets its own `console`; output after a script has finished goes to the app's stderr.
- Several scripts can run at once (they interleave at their awaits).

The globals, for now:

| | |
|---|---|
| `console.log(…)`, `console.error(…)` | a line of output (values other than strings as JSON) |
| `sleep(ms)`, `setTimeout(fn, ms)` | waiting |
| `tap(x, y)` | a tap at scene points (finger down, up 60 ms later); resolves after the finger is up |
| `type(text)` | key presses for `text`, into whatever has keyboard focus |
| `ax.tree({all})` | the accessibility tree as text (`all`: with the containers on the way) |
| `ax.elements()` | the accessibility elements: `{label, value, id, traits, class, frame}` |
| `ax.find(q)` | the first element whose label contains `q` (a string) or matches it (a RegExp), or whose id is `q` |
| `tapOn(q)` | `tap` the center of `ax.find(q)`; throws if nothing matches |
| `views()` | the view hierarchy as text |
| `objc(target, "sel:", …args)` | send a message (`target`: an object from an earlier call, or a class name); objects, numbers, booleans, selectors and CGPoint/CGSize/CGRect convert both ways |
| `cls(name)`, `desc(obj)`, `methods(class, filter)`, `classes(filter)` | exploring the Objective-C runtime |

`SCRIPT_DISABLE=1` (or Launch Options ▸ Services) launches an app that can't run scripts; `SCRIPT_VERBOSE=1` logs
timings to its stderr.

## How it works

script.dylib is injected into every app. It links only what apps load anyway; JavaScriptCore is loaded on the first
script and UIKit's accessibility support on the first `ax.*` call, so an app that is never scripted pays for neither.

```
simrun eval ──unix socket──▶ SimRun ──Mach──▶ script.dylib (in the app)
  { action: eval,             finds the        SR_MSG_SCRIPT_EVAL: the source (out of line) + a send right to a
    instance, source }        instance          port SimRun made for this one script
  ◀── { log } … { result }  ◀── drains that ◀── SR_MSG_SCRIPT_OUTPUT: each console line, then the result or
      or { exception }          port off its    exception; then it releases the right
                                main thread
```

- At start, script.dylib sends SR_MSG_SCRIPT_HELLO with its port to the session port (`mach_ports_lookup()[0]`), as
  hid.dylib does with its input port (protocol.h). Only apps get script.dylib, not the helpers they spawn, so nothing
  else says hello in their place.
- SimRun asks for a no-senders notification on each script's reply port: if the app exits or crashes mid-script, the
  client gets `{ error: "the app went away before the script finished" }` instead of waiting forever.
- The reply port's queue limit is raised to the maximum, and SimRun drains it on a queue of its own, so a script
  printing thousands of lines doesn't stall (3000 lines arrive in order).
- If the client goes away (Ctrl-C), the script still runs to the end; its output is dropped.

## JavaScriptCore

- Loaded with `dlopen` and used through `NSClassFromString`; script.dylib doesn't link it, so apps that never run a
  script don't pay for it.
- `dlopen` itself takes ~1 ms (JavaScriptCore is in the shared cache). Creating the first `JSContext` takes 5–125 ms,
  ~100 ms typically. Later scripts cost only what they do (0.3–5 ms for small ones).
- Scripts are compiled with `evaluateScript:withSourceURL:` (`script.js`) as `(async function (console) { return
  (<script>\n) })`, or with the script as statements when that isn't valid. Compiling only defines the function, so
  trying both is harmless, and the wrapper sits on the script's first line, so the lines in stack traces are the
  script's (columns on line 1 are corrected for the wrapper).
- Promises work without an event loop of our own: JSC drains microtasks when the outermost call into JS returns, so
  `setTimeout` (a `dispatch_after` on the main queue) is all that's needed. `tap()` returns a promise resolved after
  the finger is lifted.

## The accessibility tree

Walking from the windows the way an AX client does (`isAccessibilityElement`; `accessibilityElements` or
`accessibilityElementAtIndex:` on containers, else subviews) finds **nothing** in a SwiftUI app by default: the hosting
view has no accessibility children, and even UIKit's own labels aren't elements. UIKit loads its accessibility support
only when the `ApplicationAccessibilityEnabled` setting (`_AXSApplicationAccessibilityEnabled()`, libAccessibility) is
on at launch:

| Attempt | Result |
|---|---|
| `_AXSApplicationAccessibilitySetEnabled(1)` after launch | the setting changes, nothing else happens (the change notification doesn't reach the app, or isn't acted on) |
| `_AXSSetAutomationEnabled(1)` after launch (what KIF does, before launch) | nothing |
| `-[UIApplication _accessibilityInit]` with the setting off | nothing |
| Both settings on, then launch | full tree; ~70 AX bundles loaded at launch |
| **Setting on, `-[UIApplication _updateApplicationAccessibility]`, setting off again** | **full tree** |

The last one is what `ax.enable()` does (`SREnsureAX`), on the first `ax.*` call. Turning the setting off right away
matters: it is stored in the shared `com.apple.Accessibility` preferences, so every app launched while it's on would
load accessibility at launch. Once loaded, the support stays, and the tree keeps following the UI after the setting is
turned off (verified across navigation pushes and pops).

Cost of the first `ax.*` call: 1.4 s warm, 4.2 s with another app launching at the same time. It loads an AX bundle
for each framework the app has loaded: 45 bundles for Showcase, 1 (UIKit.axbundle) for the UIKit-only Hello app.
Walking the tree afterwards takes 7–30 ms for ~20 elements (~190 ms the first time, while SwiftUI builds its nodes).

What it looks like (Showcase's Keyboard page, trimmed):

```
SwiftUI.AccessibilityNode [image] "Keyboard, Filled" id=keyboard.fill (27,140 30x19)
SwiftUI.AccessibilityNode [text] "Keyboard" (82,126 99x26)
SwiftUI.VerticalTextView [textEntry] value="Type something…" (44,252 378x22)
SwiftUI.AccessibilityNode [button] "Jump" (32,583 91x34)
SwiftUI.AccessibilityNode [button] "Clear" (133,583 89x34)
UIAccessibilityBackButtonElement [button] "Showcase" id=BackButton (20,62 44x44)
UILabel [header] "Keyboard" (195,74 76x21)
```

Labels, values, traits and identifiers are what a selector API needs (`getByRole("button", {name: "Jump"})`,
`getByTestId("BackButton")`). Frames are in screen points, which are scene points here, so they go straight to
`SRHIDTouch`. SF Symbol images get the symbol's name as their identifier. Showcase sets no
`.accessibilityIdentifier()` of its own, so app-set identifiers are still to be checked.

## Gotchas found

- **Descriptors leak into the app's children.** The app spawns helpers (MTLCompilerService when it compiles new
  shaders, typically on the first visit to a page; WebKit's processes), and they inherit every descriptor that isn't
  close-on-exec. In the spike, which used a unix socket per app, a connection inherited by such a helper never saw
  EOF after the app closed it, and two scripts hung their client this way. The Mach channel avoids that by design.
  SimRun had the same leak with its own descriptors.
- Off-screen cells of lazy containers report stale frames (several elements at the same y below the screen), so a
  snapshot needs a visibility filter (intersect with the window) and taps need scrolling into view.
- The walker descends into elements' children (`UIButton` → `UIButtonLabel`); an AX client stops at an element.
- Loading WebKit.axbundle and WebCore.axbundle logs a duplicate-class warning (`UIAccessibilityLoaderWebShared`).
  It looks harmless.

## Next steps

- Snapshot format for agents: visible elements only, compact text, stable refs (`[ref=e7]`) that actions accept.
- Actions that wait: until the element exists, is visible and enabled, and has stopped moving; then until the UI settles
  (no new frame from SimFramebuffer for N ms).
- An execution time limit (`JSContextGroupSetExecutionTimeLimit`): today `while (true)` hangs the app.
- Unawaited-promise detection, errors that suggest near matches, cancelling a script when its client goes away.
- Perhaps a cheaper accessibility load: only UIKit.axbundle and SwiftUI.axbundle instead of one per loaded framework.
- Try the iOS 26.5 and 18.6 runtimes. Everything above was measured on iOS 27.1.
