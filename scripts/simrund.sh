#!/bin/zsh
# simrund.sh status | stop | log — manage the shared SimRun server.
SOCK="${SIMRUND_SOCKET:-$HOME/Library/Developer/SimRun/simrund.sock}"
LOG="$HOME/Library/Logs/SimRun/simrund.log"
case "$1" in
  status) if pgrep -f "bin/simrund --serve" >/dev/null; then echo "running (pid $(pgrep -f 'bin/simrund --serve' | tr '\n' ' '))"; else echo "not running"; fi ;;
  stop)   pkill -TERM -f "bin/simrund --serve" && echo stopped || echo "not running" ;;
  log)    exec tail -f "$LOG" ;;
  *)      echo "usage: simrund.sh status|stop|log" >&2; exit 2 ;;
esac
