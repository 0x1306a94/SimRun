#!/bin/zsh
# simrund.sh status | stop | log — manage the running SimRun server (SimRun.app, GUI or headless).
LOG="$HOME/Library/Logs/SimRun/simrund.log"
case "$1" in
  status) P=$(pgrep -x SimRun | tr '\n' ' '); [[ -n "$P" ]] && echo "running (pid $P)" || echo "not running" ;;
  stop)   pkill -TERM -x SimRun && echo stopped || echo "not running" ;;
  log)    exec tail -f "$LOG" ;;
  *)      echo "usage: simrund.sh status|stop|log" >&2; exit 2 ;;
esac
