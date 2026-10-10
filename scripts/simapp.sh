#!/bin/zsh
# simapp.sh <Sim.app | sim-binary> [args] — run an iOS-Simulator app from the terminal.
# The app runs inside SimRun.app (started headless on first use if it isn't open): one window per app, shared simns
# + daemons; its output goes to this terminal and this script exits with the app's status.
# SIMAPP_STANDALONE=1 runs the app in its own private SimRun process instead.
ROOT="${0:A:h:h}"
BUILD="${SIMRUN_BUILD:-$ROOT/build}"
APP="$BUILD/SimRun.app"
[[ -x "$APP/Contents/MacOS/SimRun" ]] || { echo "simapp: not built — run 'make' in $ROOT" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: simapp.sh <Sim.app | sim-binary> [args...]" >&2; exit 2; }
T="$1"; shift
if [[ -d "$T" ]]; then EXE="$T/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$T/Info.plist")"; else EXE="$T"; fi
L="$APP/Contents/Resources/lib"
export SIMULATOR_FRAMEBUFFER_FRAMEWORK="$L/SimFramebuffer"
export SIMNS_INSERT="$L/rshim.dylib:$L/glue.dylib:$L/scenes.dylib:$L/hid.dylib:$L/pboard.dylib${SIMAPP_EXTRA_INSERT:+:$SIMAPP_EXTRA_INSERT}"
export SIMRUN_TITLE="${SIMRUN_TITLE:-$(basename "$T" .app)}"
if [[ -n "$SIMAPP_STANDALONE" ]]; then
  exec "$ROOT/scripts/simrun.sh" "$APP/Contents/MacOS/SimRun" --run "$EXE" "$@"
fi
exec "$ROOT/scripts/simrun.sh" "$APP/Contents/Helpers/simapp" "$EXE" "$@"
