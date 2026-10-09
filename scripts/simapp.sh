#!/bin/zsh
# simapp.sh <Sim.app | sim-binary> [args] — run an iOS-Simulator app as a plain macOS process tree:
#   viewer (host AppKit window, IOSurface/Metal host services) -> simns (launchd_sim stand-in) -> app (+ in-process services)
ROOT="${0:A:h:h}"
BUILD="${SIMRUN_BUILD:-$ROOT/build}"
[[ -x "$BUILD/bin/viewer" ]] || { echo "simapp: not built — run 'make' in $ROOT" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: simapp.sh <Sim.app | sim-binary> [args...]" >&2; exit 2; }
T="$1"; shift
if [[ -d "$T" ]]; then EXE="$T/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$T/Info.plist")"; else EXE="$T"; fi
export SIMULATOR_FRAMEBUFFER_FRAMEWORK="$BUILD/lib/SimFramebuffer"
export SIMNS_HOST_SLOT=0
export SIMNS_INSERT="$BUILD/lib/rshim.dylib:$BUILD/lib/glue.dylib:$BUILD/lib/scenes.dylib:$BUILD/lib/hid.dylib${SIMAPP_EXTRA_INSERT:+:$SIMAPP_EXTRA_INSERT}"
export SIMRUN_TITLE="${SIMRUN_TITLE:-$(basename "$T" .app)}"
exec "$ROOT/scripts/simrun.sh" "$BUILD/bin/viewer" "$BUILD/bin/simns" "$EXE" "$@"
