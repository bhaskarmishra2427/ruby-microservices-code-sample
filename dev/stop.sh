#!/usr/bin/env bash
# Stop the services started by dev/start.sh, ads first.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/dev/tmp"

for name in ads geocoder auth; do
  pidfile="$RUN/$name.pid"

  if [[ ! -f "$pidfile" ]]; then
    echo "  $name not running"
    continue
  fi

  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "  stopped $name (pid $pid)"
  else
    echo "  $name pidfile was stale"
  fi
  rm -f "$pidfile"
done
