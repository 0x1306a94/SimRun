# Configuration and reference

## Scripts

| Command | Effect |
|---|---|
| `scripts/simapp.sh <Sim.app \| sim-binary> [args…]` | Run an app in the shared SimRun server (started headless if needed); output goes to the terminal, exits with the app's status |
| `scripts/simrund.sh status \| stop \| log` | Show whether the server is running, stop it, or follow its log (`~/Library/Logs/SimRun/simrund.log`) |
| `scripts/simrun.sh <sim-binary> [args…]` | Run any sim binary with the environment launchd_sim would set, without the SimRun server (HOME = the shared data directory) |
| `scripts/capture.sh <pgrep -f pattern> <out.png> [window title]` | Screenshot a process's largest (or titled) window |
| `scripts/crash.py <procname> [n]` | Print the latest crash report backtrace for that process |

## Environment variables

| Variable | Effect |
|---|---|
| `SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>` | Use this iOS Simulator runtime instead of the newest installed one |
| `SIMRUN_DATA=dir` | Shared data directory (default `~/Library/Developer/SimRun/data`) |
| `SIMNS_QUIET=1` | Hide simns's log (in the server log, `simrund.sh log`, for shared launches) of every service lookup (`OK` / `MISSING`) — leave it on to see what an app needs |
| `SIMNS_DAEMONS=a,b` / `none` | Labels of real sim daemons simns may launch on demand |
| `SIMAPP_EXTRA_INSERT=x.dylib` | Inject an extra sim dylib into the app |
| `SIMAPP_STANDALONE=1` | Run the app in its own private `simrund --run` instead of the shared server |
| `SIMRUND_IDLE=secs` | Shared server exits after this long without apps (default 600, 0 = never); set when it starts |
| `SIMRUND_SOCKET=path` | Use a different server socket (default `~/Library/Developer/SimRun/simrund.sock`) |
| `SCENES_W`, `SCENES_H`, `SCENES_SCALE` | Scene size in points / scale (default 402×874 @3x); SimRun sizes the display (`SIMULATOR_MAINSCREEN_*`) and window to match |
| `HID_VERBOSE=1`, `RSHIM_VERBOSE=1`, `SIMFB_VERBOSE=1`, `SCENES_VERBOSE=1`, `PBOARD_VERBOSE=1`, `DRAG_VERBOSE=1`, `KEYCHAIN_VERBOSE=1`, `WEBKIT_VERBOSE=1` | Component tracing (`SIMFB_VERBOSE` also reports the frame-copy latency) |
| `PBOARD_DISABLE=1` | No pasteboard service in the app (UIPasteboard fails as it did before pboard.dylib) |
| `DRAG_DISABLE=1` | No drag server in the app (drags lift and then go nowhere) |
| `KEYCHAIN_DISABLE=1` | SecItem calls go to the runtime's securityd again (which answers -34018, missing entitlement) |
| `WEBKIT_DISABLE=1` | WebKit's helper processes aren't launched (web views stay blank) |
| `LOCALE_DISABLE=1` | Don't copy the Mac's language & region settings into the device's global preferences (keep what is there, e.g. to test another locale) |
| `SIMFB_CHECK=1` | Frame diagnostics: stale pixels outside partial presents (app side), and buffers overwritten while on screen (server log) |
| `SIMRUN_DEBUG_STALL=ms`, `SIMRUN_CHROME_DEMO=secs` | Testing: block SimRun's main thread for *ms* every 100 ms; toggle the window chrome on a timer (no mouse needed) |
| `OS_ACTIVITY_DT_MODE=1` | Mirror os_log/NSLog to stderr |

## Keyboard shortcuts

In an app window: ⌘R relaunch, ⌘L log (the app's stdout/stderr), ⌘Q or ⌘W quit the app, ⌘0 launcher, ⇧⌘K Keychain
window, ⌥⌘Q quit SimRun (⌘Q in SimRun's own windows). Edit menu commands (undo, redo, cut, copy, paste, delete,
select all) go to the app while one of its windows is key.

## Known gaps

- No RunningBoard: backgrounded apps keep running.
- No on-screen keyboard (needs SpringBoard hosting); the hardware keyboard mapping is US-positional
  ([hid.md](hid.md)).
- First text-field focus stalls ~2–3 s.
- Rotation: scenes can be rotated ([scenes.md](scenes.md)), but the viewer has no way to rotate and doesn't map
  input into rotated space; `deviceOrientation` and the accelerometer aren't wired.
- No audio; notifyd is not provided.
- App extensions and embedded frameworks are untested.
- No secure paste (`UIPasteControl`) or pasteboard pattern detection ([pasteboard.md](pasteboard.md)).
- No LaunchServices: UTType knows only the built-in core types.
- Drag & drop only within an app ([dragdrop.md](dragdrop.md)).
- Keychain items have no access control: stored in plaintext, never prompt for Face ID or a passcode
  ([keychain.md](keychain.md)).
- Web views run their helper processes unsandboxed; no `SFSafariViewController` / `ASWebAuthenticationSession`
  ([webkit.md](webkit.md)).
- UIKit apps ignore SIGTERM, so ending an app is SIGTERM followed by SIGKILL after 1.5 s (no
  `applicationWillTerminate`).
- Apps must adopt the UIScene lifecycle.
