#!/usr/bin/env bash
# One time setup: install gems for all three services, then build their schemas.
# Assumes PostgreSQL and RabbitMQ are already running and that the ads role and
# both databases exist. On macOS see dev/README.md; on the VM vm/provision.sh
# does all of that first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/dev"

if [[ ! -f "$DEV/env" ]]; then
  echo "dev/env is missing. Run: cp dev/env.example dev/env" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$DEV/env"
set +a

if [[ -d "$HOME/.rbenv/shims" ]]; then
  export PATH="$HOME/.rbenv/shims:$PATH"
fi
# macOS only; a no-op on Linux.
if [[ -d /opt/homebrew/opt/postgresql@16/bin ]]; then
  export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
fi

echo "ruby: $(ruby -v)"
echo

for svc in ads auth geocoder; do
  echo "==> bundling $svc"
  ( cd "$ROOT/$svc" && bundle install )
done

echo
echo "==> loading ads schema (ActiveRecord)"
( cd "$ROOT/ads" && bundle exec rake db:schema:load )

echo
echo "==> migrating and seeding auth (Sequel)"
# db:migrate re-dumps auth/db/schema.rb as a side effect. Because it runs before
# db:seed, the dump omits sequel-seed's schema_seeds table; the table is still
# created at seed time, so discard that spurious diff with:
#   git checkout auth/db/schema.rb
( cd "$ROOT/auth" && bundle exec rake db:migrate && bundle exec rake db:seed )

echo
echo "setup complete. Start the services with dev/start.sh"
