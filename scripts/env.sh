# env.sh — locate the iOS Simulator runtime root and export it as $R.
# Override with SIMRUN_RUNTIME_ROOT=<.../RuntimeRoot>; otherwise the runtime chosen in SimRun ▸ iOS Runtime, else the
# newest installed iOS runtime is used (as SimRun itself does: src/host/simrund/environment.m). Runtimes are the ones
# CoreSimulator lists (`simctl list runtimes`), wherever they are mounted; without simctl, the usual places. simctl's
# answer stays in $SIMCTL_RUNTIMES (unset with SIMRUN_RUNTIME_ROOT) for scripts/devicetype.py.
if [[ -n "$SIMRUN_RUNTIME_ROOT" ]]; then
  R="$SIMRUN_RUNTIME_ROOT"
else
  _roots=()
  _json=$(env -u DYLD_ROOT_PATH -u DYLD_INSERT_LIBRARIES /usr/bin/xcrun simctl list runtimes --json 2>/dev/null)
  if [[ -n "$_json" ]]; then
    for (( _i = 0; ; _i++ )); do
      _p=$(print -r -- "$_json" | plutil -extract runtimes.$_i.platform raw -o - - 2>/dev/null) || break
      [[ $_p == iOS && $(print -r -- "$_json" | plutil -extract runtimes.$_i.isAvailable raw -o - - 2>/dev/null) == true ]] || continue
      _roots+=("$(print -r -- "$_json" | plutil -extract runtimes.$_i.runtimeRoot raw -o - - 2>/dev/null)")
    done
  else
    _roots=({/Library/Developer/CoreSimulator/Volumes,/private/var/run/com.apple.security.cryptexd/mnt}/iOS_*/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS*.simruntime/Contents/Resources/RuntimeRoot(N)
            /Library/Developer/CoreSimulator/Profiles/Runtimes/iOS*.simruntime/Contents/Resources/RuntimeRoot(N))
  fi
  # "version build root" per runtime; the preferred build if it is there, else the newest version
  _list=$(for _r in $_roots; do
    _sv="$_r/System/Library/CoreServices/SystemVersion.plist"
    print -r -- "$(/usr/libexec/PlistBuddy -c 'Print :ProductVersion' "$_sv" 2>/dev/null) $(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$_sv" 2>/dev/null) $_r"
  done | sort -V)
  _want=$(defaults read dev.simrun.SimRun SRRuntimeBuild 2>/dev/null)
  R=""
  [[ -n "$_want" ]] && R=$(print -r -- "$_list" | awk -v b="$_want" '$2 == b { sub(/^[^ ]+ [^ ]+ /, ""); print; exit }')
  [[ -z "$R" ]] && R=$(print -r -- "$_list" | tail -1 | sed -E 's/^[^ ]+ [^ ]+ //')
  SIMCTL_RUNTIMES="$_json"
  unset _roots _json _i _p _r _sv _list _want
fi
if [[ ! -d "$R" ]]; then echo "simrun: no iOS Simulator runtime found (set SIMRUN_RUNTIME_ROOT)" >&2; return 1 2>/dev/null || exit 1; fi
export R
