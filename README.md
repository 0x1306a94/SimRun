# SimRun

Run unmodified **iOS-Simulator** app builds as plain macOS processes: the Simulator's own UIKit, SwiftUI and
QuartzCore, without `launchd_sim`, `backboardd`, SpringBoard or Simulator.app. The system services those normally
provide are reimplemented (mostly in-process), and the app appears in an ordinary Mac window with mouse/keyboard input.

```bash
make
open build/SimRun.app                          # launcher: drop iOS Simulator .app bundles on it
scripts/simapp.sh build/apps/SUI.app           # or launch from the terminal (output + exit status in the terminal)
```

**SimRun.app** is a regular Mac app: drop iOS Simulator `.app` bundles on its window or Dock icon (or use
File ▸ Add App…, Add Xcode Builds, or Finder's Open With ▸ SimRun). The library is remembered; double-click or Launch
to run an app — the row shows a spinner while it starts and a green dot once its window appears (no blank window).
In an app window: ⌘R relaunch, ⌘L log (the app's stdout/stderr), ⌘Q or ⌘W quit the app, ⌘0 launcher, ⌥⌘Q quit
everything (⌘Q elsewhere).
⇧⌘K opens the Keychain window: what apps stored with the SecItem API, passwords in plaintext (docs/keychain.md).

Each app has its own **data container**, like an iOS sandbox container: its HOME (Documents, Library — preferences,
caches, cookies, WebKit data — and tmp) is `~/Library/Developer/SimRun/data/Containers/Data/Application/<bundle id>/`
(the executable's name for a bare binary). What is managed centrally stays in the shared data directory `data/`
(`SIMULATOR_SHARED_RESOURCES_DIRECTORY`): the keychain, app group containers (`Containers/Shared/AppGroup/`, served by
the runtime's containermanagerd to apps entitled to the group) and the shared daemons' state. In the launcher, an
app's menu has App Container ▸ Show in Finder / Reset… (deletes the container; keychain items and app group
containers are kept). Containers are a convention, not a sandbox: apps run unsandboxed as you. `scripts/simrun.sh`
on its own (no SimRun server) still runs a binary with the shared directory as HOME.

All apps run inside one SimRun process (`simapp.sh` starts it headless if SimRun.app isn't open; headless it exits
after 10 idle minutes).
Each app gets its own window; its stdout/stderr go to your terminal, `simapp.sh` exits with the app's status, and
Ctrl-C (or closing the window) ends the app. Launching into a running server takes ~0.6 s to first frame
(vs ~1.1 s standalone). `scripts/simrund.sh status|stop|log` manages the server; `SIMAPP_STANDALONE=1` runs an app in
its own private server instead.

Requirements: Apple Silicon, SIP disabled, Xcode with an iOS Simulator runtime installed (the newest one is picked up
automatically; override with `SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>`). Apps must adopt the UIScene lifecycle.
Developed against macOS 27.2, Xcode 27.1, iOS 27.1 runtime.

## How it works

```
simapp (client) ──unix socket──▶ build/bin/simrund   macOS AppKit server: one window per app, input forwarding, and the
  argv, env, stdio fds                   │            host-side "sim2host" services (com.apple.IOSurface.Remote via
                                         │            IOSurfaceRemoteServer, com.apple.metal.simulator via MTLSimImplementation,
                                         │            dev.simrun.pasteboard: the Mac's NSPasteboard)
                                         ├─ build/bin/simns --serve   launchd_sim stand-in speaking sim libxpc's XPC-pipe protocol;
                                         │     │                      one private namespace per app layered over a shared global one;
                                         │     └─ trustd, cfprefsd…   real sim daemons launched on demand, shared by all apps
                                         └─ each app (bootstrap port = its namespace), with DYLD_INSERT_LIBRARIES =
                                              rshim.dylib    Metal shader-compiler XPC service spawning, bootstrap fallbacks,
                                                             the Mac's language & region (locale, languages, 24-hour
                                                             time, first weekday...) into the device's global preferences
                                              glue.dylib     starts the in-process CA render server (CAWindowServer) and hosts the
                                                             scene's layers on the display (SpringBoard's job)
                                              scenes.dylib   in-process FrontBoard host (creates/updates the UIWindowScene)
                                              hid.dylib      mouse/keyboard -> IOHIDEvents -> -[UIApplication _enqueueHIDEvent:];
                                                             trackpad scroll/pinch/rotate as real touches (docs/hid.md)
                                              pboard.dylib   in-process pasteboard daemon (com.apple.pasteboard.pasted) backed
                                                             by the Mac pasteboard via simrund (docs/pasteboard.md)
                                              drag.dylib     in-process drag server (druid) for drag & drop within the app
                                                             (docs/dragdrop.md)
                                              keychain.dylib fake keychain: the SecItem API over a plaintext plist in the
                                                             data directory, shown in SimRun's Keychain window
                                                             (docs/keychain.md)
                                              webkit.dylib   launches WKWebView's helper processes (WebContent, Networking,
                                                             GPU appexes) as children of the app (docs/webkit.md)
                                            SimFramebuffer   fake SimFramebuffer: the render server's display; presented
                                                             IOSurfaces go to the app's window (include/protocol.h)
```

## Layout

| Path | Contents |
|---|---|
| `include/` | Shared headers: viewer wire protocol, simns control protocol, gpuhost, simfb, scenes and hid APIs, keychain store |
| `src/host/` | macOS side: `simrund/` (SimRun.app: server, launcher + library, per-app window sessions, environment, host pasteboard, Keychain window), `simapp/` (terminal client), `gpuhost/` (IOSurface + Metal host services) |
| `resources/` | SimRun.app's Info.plist and app icon (`AppIcon.icon`, an Icon Composer document) |
| `src/sim/` | Simulator side: `simns/` (launchd_sim stand-in), `rshim/`, `glue/`, `scenes/`, `hid/`, `pboard/`, `drag/`, `keychain/`, `webkit/`, `simfb/` |
| `scripts/` | `simapp.sh` (run an app), `simrund.sh` (server status/stop/log), `simrun.sh` (run any sim binary with the launchd_sim environment), `env.sh`, `capture.sh` (window screenshot), `crash.py` (crash-report backtrace) |
| `tools/` | `hostinput.swift` (synthesize Mac clicks/typing into the viewer), `rhost.m` (minimal render-test launcher) |
| `tests/` | Test apps (`hello` UIKit, `swiftui`, `hidtest`, `dragtest`, `webtest` WKWebView) and programs (`render/catest`, `net/nettest`, `net/nwtest`, `viewer/fakeframes`, `pboard/pbtest`, `keychain/kctest`, `locale/loctest`) |
| `catalyst/` | Approach A: `sim2mac.sh` re-tags a Simulator .app as Mac Catalyst (runs on macOS's own UIKit instead) |
| `docs/` | Write-ups (see below) |

`make` builds everything into `build/` (`SimRun.app`, `bin/`, `lib/`, `apps/`, `tests/`); `make core` builds SimRun.app
and the client. Rebuilding while SimRun is open is safe (the bundle is swapped in atomically); quit and reopen SimRun
(or `scripts/simrund.sh stop`) to pick up the new build.

## Useful knobs

| Variable | Effect |
|---|---|
| `SIMNS_QUIET=1` | Hide simns's log (in the server log, `simrund.sh log`, for shared launches) of every service lookup (`OK` / `MISSING`) — leave it on to see what an app needs |
| `SIMNS_DAEMONS=a,b` / `none` | Labels of real sim daemons simns may launch on demand |
| `SIMAPP_EXTRA_INSERT=x.dylib` | Inject an extra sim dylib into the app |
| `SIMAPP_STANDALONE=1` | Run the app in its own private `simrund --run` instead of the shared server |
| `SIMRUND_IDLE=secs` | Shared server exits after this long without apps (default 600, 0 = never); set when it starts |
| `SIMRUND_SOCKET=path` | Use a different server socket (default `~/Library/Developer/SimRun/simrund.sock`) |
| `SCENES_W`, `SCENES_H`, `SCENES_SCALE` | Scene size in points / scale (default 402×874 @3x) |
| `HID_VERBOSE=1`, `RSHIM_VERBOSE=1`, `SIMFB_VERBOSE=1`, `SCENES_VERBOSE=1`, `PBOARD_VERBOSE=1`, `DRAG_VERBOSE=1`, `KEYCHAIN_VERBOSE=1`, `WEBKIT_VERBOSE=1` | Component tracing (`SIMFB_VERBOSE` also reports the frame-copy latency) |
| `PBOARD_DISABLE=1` | No pasteboard service in the app (UIPasteboard fails as it did before pboard.dylib) |
| `DRAG_DISABLE=1` | No drag server in the app (drags lift and then go nowhere) |
| `KEYCHAIN_DISABLE=1` | SecItem calls go to the runtime's securityd again (which answers -34018, missing entitlement) |
| `WEBKIT_DISABLE=1` | WebKit's helper processes aren't launched (web views stay blank) |
| `LOCALE_DISABLE=1` | Don't copy the Mac's language & region settings into the device's global preferences (keep what is there, e.g. to test another locale) |
| `SIMFB_CHECK=1` | Frame diagnostics: stale pixels outside partial presents (app side), and buffers overwritten while on screen (server log) |
| `SIMRUN_DEBUG_STALL=ms`, `SIMRUN_CHROME_DEMO=secs` | Testing: block SimRun's main thread for *ms* every 100 ms; toggle the window chrome on a timer (no mouse needed) |
| `OS_ACTIVITY_DT_MODE=1` | Mirror os_log/NSLog to stderr |

## Docs

- `docs/research-log.md` — chronological findings from the investigation (paths in it refer to the original prototype layout)
- `docs/simns.md` — how sim libxpc finds launchd, the XPC-pipe routines, service inventory, on-demand daemons (and how
  they come back when they die)
- `docs/render.md` — in-process render server, the SimFramebuffer API, sim2host GPU/IOSurface services
- `docs/scenes.md` — how UIKit obtains a UIWindowScene and the in-process FrontBoard host
- `docs/hid.md` — input injection, keyboard focus/deferring, event fields
- `docs/pasteboard.md` — UIPasteboard ⇄ Mac pasteboard: the pasted protocol, UIKit's cache, the fake server
- `docs/dragdrop.md` — drag & drop within an app: the druid protocols, drag HID events, the in-process drag server
- `docs/keychain.md` — the fake keychain: SecItem semantics, the plaintext store, access groups, the Keychain window
- `docs/webkit.md` — WKWebView: BrowserEngineKit process launches, the extension entry point, the Launch Services wait
- `docs/approach-a-catalyst.md` — the simpler Mac Catalyst re-tagging approach

## Known gaps

No RunningBoard (backgrounded apps keep running), no on-screen keyboard (needs SpringBoard hosting), hardware keyboard
is US-positional, first text-field focus stalls ~2–3 s, rotation input mapping, no audio, notifyd not provided,
app extensions and embedded frameworks untested, no secure paste (`UIPasteControl`) or pasteboard pattern detection,
no LaunchServices (UTType knows only the built-in core types), drag & drop only within an app, keychain items have no
access control (stored in plaintext, never prompt for Face ID or a passcode).
Web views run their helper processes unsandboxed; no `SFSafariViewController` / `ASWebAuthenticationSession`.
UIKit apps ignore SIGTERM, so ending an app is SIGTERM followed by SIGKILL after 1.5 s (no applicationWillTerminate).
