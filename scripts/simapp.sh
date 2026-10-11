#!/bin/zsh
# simapp.sh [--profile <name>] <Sim.app | sim-binary> [args] — run an iOS-Simulator app from the terminal.
# The app runs inside SimRun.app (started headless on first use if it isn't open): one window per app, shared simns
# + daemons; its output goes to this terminal and this script exits with the app's status.
# --profile <name> (or SIMRUN_PROFILE=<name>) runs it in that profile: another data container of this app's, created on
# first use, so the app can run several times at once with separate data. "default" (or none) is its usual container.
# SIMAPP_STANDALONE=1 runs the app in its own private SimRun process instead.
ROOT="${0:A:h:h}"
BUILD="${SIMRUN_BUILD:-$ROOT/build}"
APP="$BUILD/SimRun.app"
USAGE="usage: simapp.sh [--profile <name>] <Sim.app | sim-binary> [args...]"
[[ -x "$APP/Contents/MacOS/SimRun" ]] || { echo "simapp: not built — run 'make' in $ROOT" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile) [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; export SIMRUN_PROFILE="$2"; shift 2 ;;
    --profile=*)  export SIMRUN_PROFILE="${1#--profile=}"; shift ;;
    --)           shift; break ;;
    -*)           echo "simapp: unknown option $1" >&2; echo "$USAGE" >&2; exit 2 ;;
    *)            break ;;
  esac
done
[[ $# -ge 1 ]] || { echo "$USAGE" >&2; exit 2; }
T="$1"; shift
if [[ -d "$T" ]]; then EXE="$T/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$T/Info.plist")"; else EXE="$T"; fi
L="$APP/Contents/Resources/lib"
export SIMULATOR_FRAMEBUFFER_FRAMEWORK="$L/SimFramebuffer"
export SIMNS_INSERT="$L/rshim.dylib:$L/glue.dylib:$L/scenes.dylib:$L/hid.dylib:$L/pboard.dylib:$L/drag.dylib:$L/keychain.dylib:$L/webkit.dylib${SIMAPP_EXTRA_INSERT:+:$SIMAPP_EXTRA_INSERT}"
export SIMRUN_TITLE="${SIMRUN_TITLE:-$(basename "$T" .app)}"
if [[ -n "$SIMAPP_STANDALONE" ]]; then
  exec "$ROOT/scripts/simrun.sh" "$APP/Contents/MacOS/SimRun" --run "$EXE" "$@"
fi
exec "$ROOT/scripts/simrun.sh" "$APP/Contents/Helpers/simapp" "$EXE" "$@"
