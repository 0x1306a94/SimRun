# SimRun

Run unmodified **iOS-Simulator** app builds as plain macOS processes: the Simulator's own UIKit, SwiftUI and
QuartzCore, without `launchd_sim`, `backboardd`, SpringBoard or Simulator.app. The system services those normally
provide are reimplemented (mostly in-process), and the app appears in an ordinary Mac window with mouse/keyboard input.

```bash
make
scripts/simapp.sh build/apps/SUI.app          # or any arm64 iOS-Simulator .app / binary
```

Requirements: Apple Silicon, SIP disabled, Xcode with an iOS Simulator runtime installed (the newest one is picked up
automatically; override with `SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>`). Apps must adopt the UIScene lifecycle.
Developed against macOS 27.2, Xcode 27.1, iOS 27.1 runtime.

## How it works

```
build/bin/viewer        macOS AppKit app: window, input forwarding, and the host-side "sim2host" services
  │                     (com.apple.IOSurface.Remote via IOSurfaceRemoteServer, com.apple.metal.simulator via MTLSimImplementation)
  └─ build/bin/simns    launchd_sim stand-in: the app's TASK_BOOTSTRAP_PORT; speaks sim libxpc's XPC-pipe protocol;
       │                launches allow-listed real sim daemons on demand (trustd, securityd, cfprefsd)
       └─ the app, with DYLD_INSERT_LIBRARIES =
            rshim.dylib    Metal shader-compiler XPC service spawning, bootstrap fallbacks
            glue.dylib     starts the in-process CA render server (CAWindowServer) and hosts the scene's layers
                           on the display (SpringBoard's job)
            scenes.dylib   in-process FrontBoard host (creates/updates the UIWindowScene), BKSDisplayServices stub
            hid.dylib      mouse/keyboard -> IOHIDEvents -> -[UIApplication _enqueueHIDEvent:], keyboard focus
       SimFramebuffer     fake SimFramebuffer (SIMULATOR_FRAMEBUFFER_FRAMEWORK): the render server's display;
                          presented IOSurfaces are sent to the viewer (include/protocol.h)
```

## Layout

| Path | Contents |
|---|---|
| `include/` | Shared headers: viewer wire protocol, simns control protocol, gpuhost, simfb, scenes and hid APIs |
| `src/host/` | macOS side: `viewer/` (window + input), `gpuhost/` (IOSurface + Metal host services) |
| `src/sim/` | Simulator side: `simns/` (launchd_sim stand-in), `rshim/`, `glue/`, `scenes/`, `hid/`, `simfb/` |
| `scripts/` | `simapp.sh` (run an app), `simrun.sh` (run any sim binary with the launchd_sim environment), `env.sh`, `capture.sh` (window screenshot), `crash.py` (crash-report backtrace) |
| `tools/` | `hostinput.swift` (synthesize Mac clicks/typing into the viewer), `rhost.m` (minimal render-test launcher) |
| `tests/` | Test apps (`hello` UIKit, `swiftui`, `hidtest`) and programs (`render/catest`, `net/nettest`, `net/nwtest`, `viewer/fakeframes`) |
| `catalyst/` | Approach A: `sim2mac.sh` re-tags a Simulator .app as Mac Catalyst (runs on macOS's own UIKit instead) |
| `docs/` | Write-ups (see below) |

`make` builds everything into `build/` (`bin/`, `lib/`, `apps/`, `tests/`); `make core` builds only what `simapp.sh` needs.

## Useful knobs

| Variable | Effect |
|---|---|
| `SIMNS_QUIET=1` | Hide simns's log of every service lookup (`OK` / `MISSING`) — leave it on to see what an app needs |
| `SIMNS_DAEMONS=a,b` / `none` | Labels of real sim daemons simns may launch on demand |
| `SIMAPP_EXTRA_INSERT=x.dylib` | Inject an extra sim dylib into the app |
| `SCENES_W`, `SCENES_H`, `SCENES_SCALE` | Scene size in points / scale (default 402×874 @3x) |
| `HID_VERBOSE=1`, `RSHIM_VERBOSE=1`, `SIMFB_VERBOSE=1`, `SCENES_VERBOSE=1` | Component tracing |
| `OS_ACTIVITY_DT_MODE=1` | Mirror os_log/NSLog to stderr |

## Docs

- `docs/research-log.md` — chronological findings from the investigation (paths in it refer to the original prototype layout)
- `docs/simns.md` — how sim libxpc finds launchd, the XPC-pipe routines, service inventory, on-demand daemons
- `docs/render.md` — in-process render server, the SimFramebuffer API, sim2host GPU/IOSurface services
- `docs/scenes.md` — how UIKit obtains a UIWindowScene and the in-process FrontBoard host
- `docs/hid.md` — input injection, keyboard focus/deferring, event fields
- `docs/approach-a-catalyst.md` — the simpler Mac Catalyst re-tagging approach

## Known gaps

No RunningBoard (backgrounded apps keep running), no on-screen keyboard (needs SpringBoard hosting), hardware keyboard
is US-positional, first text-field focus stalls ~2–3 s, rotation input mapping, no audio, notifyd not provided,
app extensions and embedded frameworks untested, possible tearing (viewer shows the live framebuffer).
