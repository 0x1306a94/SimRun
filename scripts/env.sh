# env.sh — locate the iOS Simulator runtime root and export it as $R.
# Override with SIMRUN_RUNTIME_ROOT=<.../RuntimeRoot>; otherwise the runtime chosen in SimRun ▸ iOS Runtime, else the
# newest installed iOS runtime is used (as SimRun itself does: src/host/simrund/environment.m).
if [[ -n "$SIMRUN_RUNTIME_ROOT" ]]; then
  R="$SIMRUN_RUNTIME_ROOT"
else
  _roots=(/Library/Developer/CoreSimulator/Volumes/iOS_*/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS*.simruntime/Contents/Resources/RuntimeRoot(N)
          /Library/Developer/CoreSimulator/Profiles/Runtimes/iOS*.simruntime/Contents/Resources/RuntimeRoot(N))
  R=""
  _want=$(defaults read dev.simrun.SimRun SRRuntimeBuild 2>/dev/null)
  if [[ -n "$_want" ]]; then
    for _r in $_roots; do
      [[ $(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$_r/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null) == "$_want" ]] && R="$_r" && break
    done
  fi
  [[ -z "$R" ]] && R=$(printf '%s\n' $_roots | sort -V | tail -1)
  unset _roots _want _r
fi
if [[ ! -d "$R" ]]; then echo "simrun: no iOS Simulator runtime found (set SIMRUN_RUNTIME_ROOT)" >&2; return 1 2>/dev/null || exit 1; fi
export R
