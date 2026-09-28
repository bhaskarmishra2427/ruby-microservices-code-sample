#!/usr/bin/env bash
# Start all three services in the background. Logs land in dev/log, pids in dev/tmp.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/dev"
RUN="$DEV/tmp"
LOGS="$DEV/log"

if [[ ! -f "$DEV/env" ]]; then
  echo "dev/env is missing. Run: cp dev/env.example dev/env" >&2
  exit 1
fi

# dev/env is plain KEY=value so it doubles as a systemd EnvironmentFile; set -a
# exports each assignment as it is read.
set -a
# shellcheck source=/dev/null
source "$DEV/env"
set +a

# rbenv shims honour each service's .ruby-version, so bundle and puma resolve to
# Ruby 3.3.12 even from a shell that has not initialised rbenv itself. Same path
# on macOS and Linux.
if [[ -d "$HOME/.rbenv/shims" ]]; then
  export PATH="$HOME/.rbenv/shims:$PATH"
fi

# macOS only: postgresql@16 is keg-only, so libpq's tools are not on the default
# PATH. A no-op on Linux, where apt puts them in /usr/bin.
if [[ -d /opt/homebrew/opt/postgresql@16/bin ]]; then
  export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
fi

mkdir -p "$RUN" "$LOGS"

start() {
  local name=$1 port=$2
  local pidfile="$RUN/$name.pid"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "  $name already running (pid $(cat "$pidfile"))"
    return
  fi

  # exec so the recorded pid is puma's, not the subshell's.
  ( cd "$ROOT/$name" && exec env PORT="$port" bundle exec puma -C config/puma.rb ) \
    > "$LOGS/$name.log" 2>&1 &
  echo $! > "$pidfile"
  echo "  $name -> localhost:$port (pid $(cat "$pidfile"), log dev/log/$name.log)"
}

# auth and geocoder first: their AMQP consumers are loaded as initializers inside
# their own web processes, and both must be subscribed before ads can issue an
# RPC auth call or publish a geocoding job.
echo "starting services..."
start auth 4000
start geocoder 6000
sleep 3
start ads 3000

echo
echo "waiting for listeners..."
for probe in "auth:4000" "geocoder:6000" "ads:3000"; do
  name=${probe%%:*}
  port=${probe##*:}
  for _ in $(seq 1 30); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "  $name listening on $port"
      break
    fi
    sleep 1
  done
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  $name FAILED to bind $port - see dev/log/$name.log" >&2
  fi
done
