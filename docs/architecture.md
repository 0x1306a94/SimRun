# Architecture

SimRun runs unmodified **iOS-Simulator** app builds as plain macOS processes: the Simulator's own UIKit, SwiftUI and
QuartzCore, without `launchd_sim`, `backboardd`, SpringBoard or Simulator.app. The system services those normally
provide are reimplemented (mostly in-process), and the app appears in an ordinary Mac window with mouse/keyboard input.

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
                                                             trackpad scroll/pinch/rotate as real touches (hid.md)
                                              pboard.dylib   in-process pasteboard daemon (com.apple.pasteboard.pasted) backed
                                                             by the Mac pasteboard via simrund (pasteboard.md)
                                              drag.dylib     in-process drag server (druid) for drag & drop within the app
                                                             (dragdrop.md)
                                              keychain.dylib fake keychain: the SecItem API over a plaintext plist in the
                                                             data directory, shown in SimRun's Keychain window
                                                             (keychain.md)
                                              webkit.dylib   launches WKWebView's helper processes (WebContent, Networking,
                                                             GPU appexes) as children of the app (webkit.md)
                                            SimFramebuffer   fake SimFramebuffer: the render server's display; presented
                                                             IOSurfaces go to the app's window (include/protocol.h)
```

All apps run inside one SimRun process. `simapp` (via `scripts/simapp.sh`) connects to it over a unix socket, passing
the app's argv, environment and stdio file descriptors; if SimRun.app isn't open, it is started headless and exits
after 10 idle minutes (`SIMRUND_IDLE`). Each app gets its own window; `simapp.sh` exits with the app's status, and
Ctrl-C (or closing the window) ends the app. Launching into a running server takes ~0.6 s to first frame (vs ~1.1 s
standalone, `SIMAPP_STANDALONE=1`, which runs the app in its own private `simrund --run`).

The launcher remembers its library of apps. **File ▸ Add Xcode Simulator Builds** scans
`~/Library/Developer/Xcode/DerivedData/*/Build/Products/*-iphonesimulator/` for `.app` bundles. An app is accepted
if it has a top-level `Info.plist` with a `CFBundleExecutable` whose arm64 slice is built for the `IOSSIMULATOR`
platform.

Holding ⌥ in an app's menu turns **Launch** into **Launch With…** (**Relaunch With…** while it runs; ⌥⌘R in an app
window): a sheet, like a scheme's Run action in Xcode, with the app's launch options — its iOS runtime and device,
arguments and environment variables, language & region, which SimRun services it gets, and diagnostics (os_log mirroring, component
tracing, frame checks; these are the variables in [reference.md](reference.md)). They are saved per app path
(`SRLaunchOptions` in SimRun's user defaults) and used by every launch from the launcher; apps launched from the
terminal get only what their environment says.

## Runtimes

SimRun finds the installed iOS runtimes the way Xcode does, with `xcrun simctl list runtimes`: they can be mounted
under `/Library/Developer/CoreSimulator/Volumes` (disk images), under `/private/var/run/com.apple.security.cryptexd/mnt`
(cryptexes) or installed in `/Library/Developer/CoreSimulator/Profiles/Runtimes`; those places are scanned only when
simctl can't be run. SimRun has a runtime of its own: `SIMRUN_RUNTIME_ROOT`, else the one chosen in **SimRun ▸ iOS Runtime** (a build
version, `SRRuntimeBuild` in its user defaults), else the newest installed iOS runtime. It is read once at start, so a
new choice takes effect when SimRun is reopened; the menu says so while the two differ. Its `simns --serve`, and with
it the shared daemons (cfprefsd, containermanagerd, trustd, securityd), runs from that runtime.

An app can run on another installed runtime (Launch With… ▸ Info, or `SIMRUN_RUNTIME_ROOT` in a `simapp` client's
environment). SimRun then starts a second `simns --serve` from that runtime the first time it is needed, publishes the
same host services (IOSurface, Metal, pasteboard) in it, and gives the app a namespace there, so an app never talks to
another runtime's daemons. Either way the server sets the runtime variables (`DYLD_ROOT_PATH`, `SIMULATOR_ROOT`,
`SIMULATOR_RUNTIME_VERSION`, …) itself, replacing whatever runtime a client's environment pointed at. Extra simns stay
until SimRun quits. An app whose executable needs a newer iOS than its runtime (the arm64 slice's minimum OS, which
dyld enforces) isn't started: the launcher shows why, a `simapp` client prints it. All runtimes share the data directory (app containers, keychain, app groups, preferences); apps on
two runtimes at once means two cfprefsd and containermanagerd instances over the same files.

## Devices

What device an app runs as comes from a CoreSimulator device type (a `.simdevicetype`, installed with Xcode). Its
`capabilities.plist` is what libMobileGestalt answers from in a sim process, found through `SIMULATOR_CAPABILITIES`:
the model, Dynamic Island, screen corner radius, home button, artwork traits for asset selection and so on. Without
it, MobileGestalt falls back to its defaults (no Dynamic Island, among others). The device type also gives
`SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_PRODUCT_CLASS` and the screen, `SIMULATOR_MAINSCREEN_*`. That screen is the
display the app renders into, its scene's size, and its window. scenes.dylib takes the safe area from UIKit's default
display edge info for the device, or from its kind (home-button iPhone, iPad) when UIKit has none.

The device types an app can use are the ones its runtime supports, as `simctl list runtimes` lists them (without
simctl: the installed ones whose runtime version range includes the runtime). The default is `SIMRUN_DEVICE`
(identifier or name) if the runtime supports it, else the newest supported iPhone with a 1206×2622 screen (a 6.3-inch
Pro, preferably), else the newest supported iPhone. Launch With… ▸ Info picks another for one app. `simrun.sh` makes
the same choice with `scripts/devicetype.py`, so a `simapp` client's environment carries its device; `scripts/devicetype.py
<RuntimeRoot> --list` shows a runtime's device types.

## Data containers

Each app has its own **data container**, like an iOS sandbox container: its HOME (Documents, Library — preferences,
caches, cookies, WebKit data — and tmp) is `~/Library/Developer/SimRun/data/Containers/Data/Application/<bundle id>/`
(the executable's name for a bare binary). What is managed centrally stays in the shared data directory `data/`
(`SIMULATOR_SHARED_RESOURCES_DIRECTORY`): the keychain, app group containers (`Containers/Shared/AppGroup/`, served by
the runtime's containermanagerd to apps entitled to the group) and the shared daemons' state. In the launcher, an
app's menu has App Container ▸ Show in Finder / Reset… (deletes the container; keychain items and app group
containers are kept). Containers are a convention, not a sandbox: apps run unsandboxed as you. `scripts/simrun.sh`
on its own (no SimRun server) still runs a binary with the shared directory as HOME.

## Layout

| Path | Contents |
|---|---|
| `include/` | Shared headers: viewer wire protocol, simns control protocol, gpuhost, simfb, scenes and hid APIs, keychain store |
| `src/host/` | macOS side: `simrund/` (SimRun.app: server, launcher + library, Launch With… sheet + per-app launch options, per-app window sessions, environment, runtimes and device types, host pasteboard, Keychain window), `simapp/` (terminal client), `gpuhost/` (IOSurface + Metal host services) |
| `resources/` | SimRun.app's Info.plist and app icon (`AppIcon.icon`, an Icon Composer document) |
| `src/sim/` | Simulator side: `simns/` (launchd_sim stand-in), `rshim/`, `glue/`, `scenes/`, `hid/`, `pboard/`, `drag/`, `keychain/`, `webkit/`, `simfb/` |
| `scripts/` | `simapp.sh` (run an app), `simrund.sh` (server status/stop/log), `simrun.sh` (run any sim binary with the launchd_sim environment), `env.sh`, `capture.sh` (window screenshot), `crash.py` (crash-report backtrace) |
| `tools/` | `hostinput.swift` (synthesize Mac clicks/typing into the viewer), `rhost.m` (minimal render-test launcher) |
| `tests/` | Test apps (`hello` UIKit, `swiftui`, `hidtest`, `dragtest`, `webtest` WKWebView, `glass` Liquid Glass, `showcase` a SwiftUI tour of everything that works) and programs (`render/catest`, `net/nettest`, `net/nwtest`, `viewer/fakeframes`, `pboard/pbtest`, `keychain/kctest`, `locale/loctest`) |
| `docs/` | These write-ups |

## Building

Everything builds into `build/` (`SimRun.app`, `bin/`, `lib/`, `apps/`, `tests/`). `make` builds SimRun.app, the
client, the tools and the test programs; `make core` only SimRun.app and the client, `make tools` the tools,
`make test-apps` the test apps (`build/apps/`), `make test-programs` the test programs (`build/tests/`), and
`make tests` both. Rebuilding while SimRun
is open is safe (the bundle is assembled in a staging directory and swapped in with a rename); quit and reopen SimRun
(or `scripts/simrund.sh stop`) to pick up the new build.

Requirements: Apple Silicon, SIP disabled, Xcode with an iOS Simulator runtime installed (see [Runtimes](#runtimes)).
Apps must adopt the UIScene lifecycle. Developed against macOS 27.2, Xcode 27.1, iOS 27.1 runtime; iOS 27.0 and 18.6 also work (the Showcase and Glass test
apps need iOS 26).
