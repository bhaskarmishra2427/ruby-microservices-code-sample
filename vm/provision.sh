#!/usr/bin/env bash
# Provision a fresh Ubuntu 24.04 host to run the three Ruby microservices.
# Idempotent: safe to re-run.
#
#   cp dev/env.example dev/env     # edit if you want non-default secrets
#   vm/provision.sh
#   dev/setup.sh                   # bundle install + schemas
#   vm/install-systemd.sh          # optional, recommended on a VM
#
# Installs the New Relic eBPF agent's prerequisites but NOT the agent itself: its
# install command embeds an account user key and must be copied from the New Relic
# UI. See vm/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUBY_VERSION=3.3.12

log() { printf '\n==> %s\n' "$1"; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# --- 0. Preflight ----------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "This script targets Linux. On macOS follow dev/README.md."

if [[ ! -f "$ROOT/dev/env" ]]; then
  die "dev/env is missing. Run: cp dev/env.example dev/env"
fi

# The New Relic eBPF agent supports kernels 5.8 through 7.1 inclusive. The upper
# bound is real: it will not function on a newer kernel, so fail here rather than
# after everything else is built.
KERNEL="$(uname -r)"
KMAJOR="${KERNEL%%.*}"
KREST="${KERNEL#*.}"
KMINOR="${KREST%%.*}"
if (( KMAJOR * 100 + KMINOR < 508 )) || (( KMAJOR * 100 + KMINOR > 701 )); then
  die "Kernel $KERNEL is outside the eBPF agent's supported 5.8-7.1 range.
     Ubuntu 24.04 LTS ships 6.8, which is in range."
fi
log "Kernel $KERNEL is within the eBPF agent's supported range (5.8-7.1)"

# Read PG_USER / PG_PASSWORD from the same file the services use, so the database
# role cannot drift from what they authenticate with.
set -a
# shellcheck source=/dev/null
source "$ROOT/dev/env"
set +a
: "${PG_USER:?not set in dev/env}"
: "${PG_PASSWORD:?not set in dev/env}"

# --- 1. Packages -----------------------------------------------------------

log "Installing packages"
sudo apt-get update -qq
# Ruby build dependencies, the two brokers, and lsof - which Ubuntu cloud images
# omit and dev/start.sh uses for its listener probe.
#
# rustc is deliberately absent: it is only needed to build YJIT, and leaving YJIT
# out keeps load test numbers comparable with the non-YJIT macOS baseline.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential autoconf patch \
  libssl-dev libyaml-dev libreadline-dev zlib1g-dev libgmp-dev \
  libncurses-dev libffi-dev libgdbm-dev libdb-dev uuid-dev libpq-dev \
  postgresql rabbitmq-server \
  git curl ca-certificates gnupg lsof jq

# --- 2. Locale -------------------------------------------------------------

# geocoder reads db/data/city.csv, which is UTF-8 Cyrillic. Without a UTF-8
# locale Ruby's default_external is US-ASCII and CSV.read raises
# CSV::InvalidEncodingError, failing every geocoding message.
log "Generating en_US.UTF-8 locale"
sudo locale-gen en_US.UTF-8 >/dev/null
sudo update-locale >/dev/null 2>&1 || true

# --- 3. Ruby via rbenv -----------------------------------------------------

if [[ ! -d "$HOME/.rbenv" ]]; then
  log "Cloning rbenv"
  git clone --depth 1 https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
fi
if [[ ! -d "$HOME/.rbenv/plugins/ruby-build" ]]; then
  git clone --depth 1 https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
else
  git -C "$HOME/.rbenv/plugins/ruby-build" pull --quiet --ff-only || true
fi

export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"

if [[ ! -d "$HOME/.rbenv/versions/$RUBY_VERSION" ]]; then
  log "Building Ruby $RUBY_VERSION (this takes a few minutes)"
  rbenv install -s "$RUBY_VERSION"
else
  log "Ruby $RUBY_VERSION already installed"
fi
rbenv rehash

# Convenience for interactive shells. The dev/ scripts prepend the shims
# directory themselves, so they do not depend on this.
if ! grep -q 'rbenv init' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ''
    echo '# rbenv: makes per-directory .ruby-version files take effect.'
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
    echo 'command -v rbenv >/dev/null && eval "$(rbenv init - bash)"'
  } >> "$HOME/.bashrc"
fi

# The socket extension must exist; its absence is what made Ruby 3.1 unusable on
# macOS, and a silently incomplete build here would fail much later and obscurely.
"$HOME/.rbenv/versions/$RUBY_VERSION/bin/ruby" -rsocket \
  -e 'TCPServer.new("127.0.0.1", 0).close' \
  || die "Ruby built without a working socket extension"

# --- 4. PostgreSQL ---------------------------------------------------------

log "Configuring PostgreSQL"
sudo systemctl enable --now postgresql

# Databases are created OWNED BY the app role: since PostgreSQL 15 a non-owner
# cannot create tables in the public schema, which would break db:schema:load.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'" | grep -q 1; then
  sudo -u postgres createuser --createdb "$PG_USER"
fi
sudo -u postgres psql -qc "ALTER ROLE \"$PG_USER\" WITH PASSWORD '$PG_PASSWORD';"

for db in ms-ads-production ms-auth; do
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    sudo -u postgres createdb -O "$PG_USER" "$db"
    echo "    created $db"
  else
    echo "    $db already exists"
  fi
done

# --- 5. RabbitMQ -----------------------------------------------------------

log "Configuring RabbitMQ"
sudo systemctl enable --now rabbitmq-server
# guest/guest is accepted on loopback only, which is where every service runs, so
# no user provisioning is required.
sudo rabbitmq-plugins enable rabbitmq_management >/dev/null

# --- 6. k6 -----------------------------------------------------------------

if ! command -v k6 >/dev/null; then
  log "Installing k6"
  # If the keyserver is unreachable from this network, fall back to the static
  # binary from https://github.com/grafana/k6/releases
  sudo gpg --no-default-keyring \
    --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
    --keyserver hkp://keyserver.ubuntu.com:80 \
    --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
  echo 'deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main' \
    | sudo tee /etc/apt/sources.list.d/k6.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq k6
else
  log "k6 already installed"
fi

# --- Done ------------------------------------------------------------------

cat <<EOF

Provisioning complete.

  ruby      $("$HOME/.rbenv/versions/$RUBY_VERSION/bin/ruby" -v | awk '{print $2}')
  postgres  $(sudo -u postgres psql -tAc 'SHOW server_version' | xargs)
  rabbitmq  $(sudo rabbitmqctl version 2>/dev/null | tail -1 | xargs)
  k6        $(k6 version 2>/dev/null | head -1)
  kernel    $KERNEL

Next:
  dev/setup.sh              bundle the services and build their schemas
  vm/install-systemd.sh     install and start the three systemd units
  vm/README.md              then install the New Relic eBPF agent
EOF
