#!/usr/bin/env bash
# Install the three services as systemd units and start them.
# Run after vm/provision.sh and dev/setup.sh. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNITS="$ROOT/vm/systemd"
ENV_DIR=/etc/newrelic-ms
SERVICES=(ms-auth ms-geocoder ms-ads)

[[ "$(uname -s)" == "Linux" ]] || { echo "Linux only; on macOS use dev/start.sh" >&2; exit 1; }
[[ -f "$ROOT/dev/env" ]] || { echo "dev/env is missing. Run: cp dev/env.example dev/env" >&2; exit 1; }

# dev/env is plain KEY=value precisely so it can be used verbatim here.
echo "==> Installing $ENV_DIR/env"
sudo install -d -m 755 "$ENV_DIR"
sudo install -m 600 -o root -g root "$ROOT/dev/env" "$ENV_DIR/env"

# dev/start.sh backgrounds these same processes. Running both at once would fight
# over the ports, so clear the script-managed ones first.
if [[ -d "$ROOT/dev/tmp" ]] && compgen -G "$ROOT/dev/tmp/*.pid" >/dev/null; then
  echo "==> Stopping processes started by dev/start.sh"
  "$ROOT/dev/stop.sh" || true
fi

echo "==> Rendering units"
for svc in "${SERVICES[@]}"; do
  sed -e "s|__ROOT__|$ROOT|g" \
      -e "s|__USER__|$USER|g" \
      -e "s|__HOME__|$HOME|g" \
      "$UNITS/$svc.service" \
    | sudo tee "/etc/systemd/system/$svc.service" >/dev/null
  echo "    /etc/systemd/system/$svc.service"
done

sudo systemctl daemon-reload

echo "==> Enabling and starting"
# ms-ads last, and its unit's After= ordering enforces the same sequence on boot.
for svc in "${SERVICES[@]}"; do
  sudo systemctl enable --now "$svc" >/dev/null
done

echo "==> Waiting for listeners"
for probe in ms-auth:4000 ms-geocoder:6000 ms-ads:3000; do
  svc=${probe%%:*}
  port=${probe##*:}
  for _ in $(seq 1 30); do
    if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
      echo "    $svc listening on $port"
      break
    fi
    sleep 1
  done
  if ! ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    echo "    $svc FAILED to bind $port - journalctl -u $svc -n 50 --no-pager" >&2
  fi
done

cat <<'EOF'

Installed. Useful commands:

  systemctl status ms-ads ms-auth ms-geocoder
  journalctl -u ms-ads -f | jq .          # services log JSON to journald
  sudo systemctl restart ms-ads
  sudo rabbitmqctl list_queues name messages messages_unacknowledged

Note: changing dev/env requires re-running this script (it copies the file into
/etc/newrelic-ms/env), then `sudo systemctl restart ms-ads ms-auth ms-geocoder`.
EOF
