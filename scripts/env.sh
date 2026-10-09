# env.sh — locate the iOS Simulator runtime root and export it as $R.
# Override with SIMRUN_RUNTIME_ROOT=<.../RuntimeRoot>; otherwise the newest installed iOS runtime is used.
if [[ -n "$SIMRUN_RUNTIME_ROOT" ]]; then
  R="$SIMRUN_RUNTIME_ROOT"
else
  R=$(ls -d /Library/Developer/CoreSimulator/Volumes/iOS_*/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS*.simruntime/Contents/Resources/RuntimeRoot 2>/dev/null | sort -V | tail -1)
fi
if [[ ! -d "$R" ]]; then echo "simrun: no iOS Simulator runtime found (set SIMRUN_RUNTIME_ROOT)" >&2; return 1 2>/dev/null || exit 1; fi
export R
