#!/bin/zsh
# simrun.sh <sim-binary> [args...] — run an iOS-simulator Mach-O as a plain host process (no launchd_sim)
source "${0:A:h}/env.sh" || exit 1
# the simulated device: SIMRUN_DEVICE, else the runtime's default (`scripts/devicetype.py "$R" --list` shows them)
_dev=("${(@f)$(print -rn -- "$SIMCTL_RUNTIMES" | /usr/bin/python3 -I "${0:A:h}/devicetype.py" "$R")}")
D="${SIMRUN_DATA:-$HOME/Library/Developer/SimRun/data}"
mkdir -p "$D/tmp" "$D/Library/Preferences" "$D/Documents"
export DYLD_ROOT_PATH="$R" IPHONE_SIMULATOR_ROOT="$R" SIMULATOR_ROOT="$R"
export DYLD_SHARED_CACHE_DIR="$R/System/Library/Caches/com.apple.dyld"
export DYLD_FALLBACK_FRAMEWORK_PATH="$R/System/Library/Frameworks" DYLD_FALLBACK_LIBRARY_PATH="$R/usr/lib"
export HOME="$D" CFFIXED_USER_HOME="$D" TMPDIR="$D/tmp/" IPHONE_SHARED_RESOURCES_DIRECTORY="$D" SIMULATOR_SHARED_RESOURCES_DIRECTORY="$D"
export SIMULATOR_HOST_HOME="${SIMRUN_HOST_HOME:-/Users/$USER}"
SV="$R/System/Library/CoreServices/SystemVersion.plist"
export SIMULATOR_RUNTIME_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ProductVersion' "$SV" 2>/dev/null)
export SIMULATOR_RUNTIME_BUILD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$SV" 2>/dev/null)
export SIMULATOR_ARCHS=arm64
export SIMULATOR_DEVICE_NAME="SimRun" SIMULATOR_UDID=00000000-0000-0000-0000-000000000000 SIMULATOR_LEGACY_ASSET_SUFFIX=iphone
export SIMULATOR_MAINSCREEN_WIDTH=1206 SIMULATOR_MAINSCREEN_HEIGHT=2622 SIMULATOR_MAINSCREEN_SCALE=3.000000 SIMULATOR_MAINSCREEN_PITCH=460.000000
unset SIMULATOR_CAPABILITIES SIMULATOR_MODEL_IDENTIFIER SIMULATOR_PRODUCT_CLASS
for _kv in $_dev; do export "$_kv"; done   # no device type: SimFramebuffer's default display, MobileGestalt's defaults
[[ -n "$SIMRUN_W" ]] && export SIMULATOR_MAINSCREEN_WIDTH=$SIMRUN_W
[[ -n "$SIMRUN_H" ]] && export SIMULATOR_MAINSCREEN_HEIGHT=$SIMRUN_H
[[ -n "$SIMRUN_SCALE" ]] && export SIMULATOR_MAINSCREEN_SCALE=$SIMRUN_SCALE
export SIMULATOR_BOOT_TIME=$(date +%s) XPC_FLAGS=0x0 LS_ENABLE_BUNDLE_LOCALIZATION_CACHING=1
[[ -n "$SIMRUN_INSERT" ]] && export DYLD_INSERT_LIBRARIES="$SIMRUN_INSERT"
exec "$@"
