#!/bin/zsh
# simrund.sh status | stop | log | profiles — manage the running SimRun server (SimRun.app, GUI or headless);
# profiles [app id] lists each app's profiles (simapp.sh --profile): the data containers it has besides its default one.
LOG="$HOME/Library/Logs/SimRun/simrund.log"
DATA="${SIMRUN_DATA:-$HOME/Library/Developer/SimRun/data}"
C="$DATA/Containers/Data"
case "$1" in
  status)   P=$(pgrep -x SimRun | tr '\n' ' '); [[ -n "$P" ]] && echo "running (pid $P)" || echo "not running" ;;
  stop)     pkill -TERM -x SimRun && echo stopped || echo "not running" ;;
  log)      exec tail -f "$LOG" ;;
  profiles) ids=("$C"/Application/*(N/:t) "$C"/Profiles/*(N/:t)); [[ -n "$2" ]] && ids=("$2")
            for a in ${(ou)ids}; do
              p=("$C/Profiles/$a"/*(N/:t)); [[ -d "$C/Application/$a" ]] && p=(default $p)
              echo "$a: ${(j:, :)p:-(none)}"
            done ;;
  *)        echo "usage: simrund.sh status|stop|log|profiles [app id]" >&2; exit 2 ;;
esac
