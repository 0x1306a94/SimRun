# Configuration and reference

## Command line

`build/bin/simrun` (also `SimRun.app/Contents/Helpers/simrun`; `simrun help` lists the commands). It talks to SimRun
over its socket; `run`, `profiles`, `runtimes` and `devices` start SimRun headless if it isn't running.

| Command | Effect |
|---|---|
| `simrun run [options] <Sim.app \| sim-binary> [args…]` | Run an app in SimRun; output goes to the terminal, Ctrl-C quits it, exits with the app's status. `-p`/`--profile <name>`: with that profile's data container ([architecture.md](architecture.md#data-containers)); `-r`/`--runtime <build, version or RuntimeRoot>`: on that runtime; `-d`/`--device <name or identifier>`: as that device type; `--insert <dylib>`: inject another sim dylib |
| `simrun list` | The running apps: pid, app, profile, device, runtime |
| `simrun quit <pid \| app> [-p <profile>]` | Quit a running app (by name, bundle ID or executable; `-p` picks among its profiles); returns once it has exited |
| `simrun screenshot <pid \| app> [-p <profile>] [-o <file.png>]` | Save the app's screen as it last drew it, at its pixel size (default `./<app>.png`) |
| `simrun eval <pid \| app> [-p <profile>] [<script> \| -f <file>]` | Run JavaScript in a running app ([scripting.md](scripting.md)): prints its console output as it happens, then its value; exits 1 if it throws. The script is the argument, the file (`-` for stdin), or stdin |
| `simrun profiles [<bundle ID \| Sim.app>]` | Apps' data containers: `default` and their profiles |
| `simrun runtimes` | The installed iOS runtimes (`*`: SimRun's) |
| `simrun devices [-r <runtime>]` | A runtime's device types (`*`: the default) |
| `simrun status \| stop \| log` | Whether SimRun is running; quit it and its apps; follow its log (`~/Library/Logs/SimRun/simrund.log`) |
| `tools/crash.py <procname> [n]` | Print the latest crash report backtrace for that process |

## Environment variables

SimRun reads its variables (`SIMRUN_*`, `SIMNS_*`, `SIMRUND_*`) when it starts: from `simrun`'s environment when
`simrun` starts it. An app gets the environment of the `simrun run` that launched it, so the component variables
(`HID_VERBOSE=1`, `PBOARD_DISABLE=1`, `OS_ACTIVITY_DT_MODE=1`, …) go before `simrun run`; for launcher launches, set
them in Launch With….

| Variable | Effect |
|---|---|
| `SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>` | SimRun's own runtime, instead of the one chosen in SimRun ▸ iOS Runtime (default: the newest installed): its shared services', and apps' unless they have their own (Launch With…, `simrun run --runtime`) |
| `SIMRUN_DEVICE=<identifier or name>` | The device type apps run as unless they have their own (Launch With…, `simrun run --device`), e.g. `"iPhone SE (3rd generation)"`, when their runtime supports it; else the runtime's default ([architecture.md](architecture.md#devices)). `simrun devices` lists them |
| `SIMRUN_DATA=dir` | Shared data directory (default `~/Library/Developer/SimRun/data`) |
| `SIMNS_QUIET=1` | Hide simns's log (in SimRun's log, `simrun log`) of every service lookup (`OK` / `MISSING`) — leave it on to see what an app needs |
| `SIMNS_DAEMONS=a,b` / `none` | Labels of real sim daemons simns may launch on demand |
| `SIMAPP_EXTRA_INSERT=x.dylib` | Inject an extra sim dylib into apps launched from the launcher (`simrun run --insert` for one launch) |
| `SIMRUND_IDLE=secs` | SimRun, started headless by `simrun`, quits after this long without apps (default 600, 0 = never) |
| `SIMRUND_SOCKET=path` | Use a different server socket (default `~/Library/Developer/SimRun/simrund.sock`) |
| `SCENES_W`, `SCENES_H`, `SCENES_SCALE` | Scene size in points / scale (default: the device type's screen); SimRun sizes the display (`SIMULATOR_MAINSCREEN_*`) and window to match |
| `HID_VERBOSE=1`, `RSHIM_VERBOSE=1`, `SIMFB_VERBOSE=1`, `SCENES_VERBOSE=1`, `PBOARD_VERBOSE=1`, `DRAG_VERBOSE=1`, `DOCPICKER_VERBOSE=1`, `KEYCHAIN_VERBOSE=1`, `WEBKIT_VERBOSE=1`, `MPS_VERBOSE=1`, `SCRIPT_VERBOSE=1` | Component tracing (`SIMFB_VERBOSE` also reports the frame-copy latency) |
| `PBOARD_DISABLE=1` | No pasteboard service in the app (UIPasteboard fails as it did before pboard.dylib) |
| `DRAG_DISABLE=1` | No drag server in the app (drags lift and then go nowhere) |
| `DOCPICKER_DISABLE=1` | Document pickers aren't served by Mac panels (they present an empty sheet) |
| `KEYCHAIN_DISABLE=1` | SecItem calls go to the runtime's securityd again (which answers -34018, missing entitlement) |
| `WEBKIT_DISABLE=1` | WebKit's helper processes aren't launched (web views stay blank) |
| `MPS_DISABLE=1` | MPSGraph's simulator bugs aren't worked around (on iOS 26 and later runtimes, graphs abort as in Simulator.app) |
| `SCRIPT_DISABLE=1` | `simrun eval` can't run scripts in the app |
| `LOCALE_DISABLE=1` | Don't copy the Mac's language & region settings into the device's global preferences (keep what is there, e.g. to test another locale) |
| `SIMFB_CHECK=1` | Frame diagnostics: stale pixels outside partial presents (app side), and buffers overwritten while on screen (server log) |
| `SIMRUN_DEBUG_STALL=ms`, `SIMRUN_CHROME_DEMO=secs` | Testing: block SimRun's main thread for *ms* every 100 ms; toggle the window chrome on a timer (no mouse needed) |
| `OS_ACTIVITY_DT_MODE=1` | Mirror os_log/NSLog to stderr |

## Keyboard shortcuts

In an app window: ⌘R relaunch, ⌥⌘R relaunch with other launch options, ⌘L log (the app's stdout/stderr), ⌘Q or ⌘W quit the app, ⌘0 launcher, ⇧⌘K Keychain
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
- Background URLSession transfers continue while the app isn't running (nsurlsessiond does them), but the app isn't
  relaunched when they finish: it gets their events the next time it starts and makes the session. Two profiles of
  one app running at once share its background sessions (nsurlsessiond knows apps by bundle ID).
- App extensions and embedded frameworks are untested.
- No secure paste (`UIPasteControl`) or pasteboard pattern detection ([pasteboard.md](pasteboard.md)).
- No LaunchServices: UTType knows only the built-in core types.
- Drag & drop only within an app ([dragdrop.md](dragdrop.md)).
- Document pickers show the Mac's file system, not file providers; `UIDocumentBrowserViewController` isn't covered
  ([docpicker.md](docpicker.md)).
- Keychain items have no access control: stored in plaintext, never prompt for Face ID or a passcode
  ([keychain.md](keychain.md)).
- Web views run their helper processes unsandboxed; no `SFSafariViewController` / `ASWebAuthenticationSession`
  ([webkit.md](webkit.md)).
- UIKit apps ignore SIGTERM, so ending an app is SIGTERM followed by SIGKILL after 1.5 s (no
  `applicationWillTerminate`).
- Apps must adopt the UIScene lifecycle.
