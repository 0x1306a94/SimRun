#!/bin/zsh -e
# sim2mac.sh <Sim.app> <Out.app> — repackage an arm64 iOS-Simulator .app as a Mac Catalyst .app
SRC=$1; DST=$2
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Info.plist")
rm -rf "$DST"; mkdir -p "$DST/Contents/MacOS" "$DST/Contents/Resources"
# resources & frameworks
for f in "$SRC"/*(N); do
  case ${f:t} in
    $EXE|Info.plist|_CodeSignature|embedded.mobileprovision) ;;
    Frameworks) cp -R "$f" "$DST/Contents/Frameworks" ;;
    PlugIns) ;;  # app extensions not handled
    *) cp -R "$f" "$DST/Contents/Resources/" ;;
  esac
done
cp "$SRC/$EXE" "$DST/Contents/MacOS/$EXE"
cp "$SRC/Info.plist" "$DST/Contents/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$DST/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$DST/Contents/Info.plist"
# retag every Mach-O: IOSSIMULATOR -> MACCATALYST, and fix iOS-style @rpath layout
retag() {
  vtool -set-build-version maccatalyst 17.0 27.0 -replace -output "$1" "$1" 2>/dev/null
}
retag "$DST/Contents/MacOS/$EXE"
install_name_tool -add_rpath @executable_path/../Frameworks "$DST/Contents/MacOS/$EXE" 2>/dev/null || true
if [[ -d "$DST/Contents/Frameworks" ]]; then
  for m in $(find "$DST/Contents/Frameworks" -type f -perm +111); do
    file "$m" | grep -q Mach-O && retag "$m"
  done
fi
codesign -s - -f --deep "$DST" 2>/dev/null
echo "built $DST"
