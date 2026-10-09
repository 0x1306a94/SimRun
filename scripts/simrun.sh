#!/bin/zsh
# simrun.sh <sim-binary> [args...] — run an iOS-simulator Mach-O as a plain host process (no launchd_sim)
source "${0:A:h}/env.sh" || exit 1
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
export SIMULATOR_DEVICE_NAME="SimRun" SIMULATOR_MODEL_IDENTIFIER=iPhone19,4 SIMULATOR_PRODUCT_CLASS=V68
export SIMULATOR_CAPABILITIES="/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist"
export SIMULATOR_MAINSCREEN_WIDTH=${SIMRUN_W:-1206} SIMULATOR_MAINSCREEN_HEIGHT=${SIMRUN_H:-2622} SIMULATOR_MAINSCREEN_SCALE=${SIMRUN_SCALE:-3.000000} SIMULATOR_MAINSCREEN_PITCH=460.000000
export SIMULATOR_UDID=00000000-0000-0000-0000-000000000000 SIMULATOR_LEGACY_ASSET_SUFFIX=iphone
export SIMULATOR_BOOT_TIME=$(date +%s) XPC_FLAGS=0x0 LS_ENABLE_BUNDLE_LOCALIZATION_CACHING=1
[[ -n "$SIMRUN_INSERT" ]] && export DYLD_INSERT_LIBRARIES="$SIMRUN_INSERT"
exec "$@"
