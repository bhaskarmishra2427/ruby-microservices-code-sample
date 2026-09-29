# Running the microservices locally (macOS)

For the Ubuntu VM deployment with the New Relic eBPF agent, see
[vm/README.md](../vm/README.md) — the application code is identical either way.

Three Ruby services on the host, no containers, against brew-managed PostgreSQL and
RabbitMQ. The cross-service topology is the **async** one: `ads` talks to `auth` over
an AMQP RPC call and hands geocoding to `geocoder` over a durable queue.

```
       POST /api/v1/ads
              |
              v
        +-----------+   AMQP RPC (queue: auth, amq.rabbitmq.reply-to)   +--------+
        |    ads    | <-----------------------------------------------> |  auth  |
        |   :3000   |                                                   | :4000  |
        +-----------+                                                   +--------+
              |
              | AMQP publish (queue: geocoding, durable)
              v
        +-----------+
        | geocoder  |
        |   :6000   |
        +-----------+
              |
              | PUT /api/v1/ads/:id   (no queue alternative exists for this hop)
              v
        +-----------+
        |    ads    |
        +-----------+
```

`ads` owns `ms-ads-production` via ActiveRecord, `auth` owns `ms-auth` via Sequel, and
`geocoder` is stateless (it reads `db/data/city.csv` into memory).

## One-time setup

```bash
brew install rbenv ruby-build postgresql@16 rabbitmq k6
eval "$(rbenv init - zsh)"          # also added to ~/.zshrc
rbenv install 3.3.12

brew services start postgresql@16
brew services start rabbitmq

export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
createuser -s ads
psql -d postgres -c "ALTER ROLE ads WITH PASSWORD 'ads';"
createdb -O ads ms-ads-production
createdb -O ads ms-auth

cp dev/env.example dev/env
dev/setup.sh                        # bundle install x3, then schema + seeds
```

Databases are created **owned by** `ads` deliberately: since PostgreSQL 15, a
non-owner cannot create tables in the `public` schema, which would break
`db:schema:load`.

## Day to day

```bash
dev/start.sh     # auth and geocoder first, then ads
dev/stop.sh
tail -f dev/log/ads.log | jq .      # all three log JSON to stdout
```

Services run with `RACK_ENV=production`. That is deliberate:
`geocoder/config/settings/` contains only `production.yml`, so development mode would
need new settings files for two services; and development mode enables
`Sinatra::Reloader`, which stats files on every request and would distort load test
numbers.

## Seeded users

`auth`'s seeds create three users, all with password `qwerty123`:
`tom@gmail.com`, `logan@gmail.com`, `jack@gmail.com`.

## Manual smoke test

```bash
TOKEN=$(curl -s -X POST localhost:4000/api/v1/sign_in \
  -H 'Content-Type: application/json' \
  -d '{"email":"tom@gmail.com","password":"qwerty123"}' | jq -r .meta.token)

curl -s -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"test","description":"test","city":"Майкоп"}}' | jq .

# lat/lon arrive asynchronously, a moment later
sleep 2
curl -s localhost:3000/api/v1/ads -H "Authorization: Bearer $TOKEN" | jq '.data[0]'
```

**City names must come from `geocoder/db/data/city.csv`** — they are Russian, in
Cyrillic. `Geocoder::FindService` returns `nil` for a miss and the queue consumer
passes that straight into `coords[0]`, raising `NoMethodError` and leaving the message
unacked. `loadtest/cities.json` holds all 1,093 valid names.

## Load test

```bash
k6 run loadtest/ads-flow.js
```

`setup()` signs in once, shares the JWT across all VUs, and runs a preflight that
creates one ad and waits for its coordinates — so a broken async chain fails in
seconds rather than after ten minutes of meaningless load.

## Useful checks

```bash
export PATH="/opt/homebrew/opt/rabbitmq/sbin:$PATH"
rabbitmqctl list_queues                 # auth and geocoding should drain to ~0
open http://localhost:15672             # guest / guest
curl -s localhost:6000/metrics | grep geocoding_process_time
```

`geocoder` already exposes Prometheus metrics at `/metrics`, including a
`geocoding_process_time` histogram — a free signal with no extra infrastructure.

## Tuning knobs worth measuring

- `auth`'s `consumer_pool` is **1** in `auth/config/settings.yml`. One thread serves
  every auth RPC call, which is the throughput ceiling of the whole system.
- `ads`'s Puma runs the default 5 threads, and the synchronous RPC blocks a thread for
  the duration of each call.
- `AUTH_RPC_TIMEOUT` (default 5s) bounds the RPC reply wait.

Measure before and after changing these rather than adjusting them silently.

## What had to change to run on Ruby 3.3 / macOS 26

The repo was written for Ruby 2.6.6 in 2021. Bringing it up:

| Change | Why |
|---|---|
| Ruby 3.3.12, not 3.1.7 | Ruby 3.1's `ext/socket/extconf.rb` reads `/usr/include/netinet6/in6.h` by absolute path. Modern macOS keeps headers in the SDK and `/usr` is SIP-protected, so 3.1 builds *without the socket extension*. 3.1 is EOL and will never be patched. |
| `activerecord`/`activesupport`/`railties` 6.1 → 7.1 | AR 6.1 is not Ruby 3.3-safe. AR 7 also reads `database.yml` with aliases enabled, which removed the need for a `psych` pin. |
| `fast_jsonapi` → `jsonapi-serializer` | `fast_jsonapi` was abandoned in 2019. The replacement dropped `serialized_json`, so the two call sites in `ads_controller.rb` now use `serializable_hash.to_json`. |
| `dry-validation` 1.5 → 1.10 | 1.5.6 resolved against `dry-schema` 1.11, which no longer has `Dry::Schema::PredicateRegistry`. Both services crashed on boot. |
| `json` pinned to `~> 2.7` | json 3.x removed the `create_additions:` keyword that `Rack::JSONBodyParser` (rack-contrib 2.5.0) still passes, turning every JSON request body into a 400. `rubocop`'s `json >= 2.3` pulled 3.x into `ads`. |
| `rack` pinned to `~> 2.2` | Sinatra 2.1 and Puma 5 need Rack 2; Rack 3 would cascade. |
| `BasicService` keyword forwarding | `def call(*args); new(*args)` silently loses keywords under Ruby 3, so `dry-initializer` saw no options and every attribute came out `nil` — with no error. Fixed in both `ads` and `auth`. |
| `require_relative 'validations'` in `auth/app/helpers/api_errors.rb` | `ApplicationLoader` globs with `Dir[]`, whose order is not guaranteed. `api_errors.rb` references `Validations::InvalidParams` at load time, so boot succeeded or failed depending on filesystem ordering. It happened to fail here. |
| `LANG`/`LC_ALL` in `dev/env` | Without a UTF-8 locale Ruby's `default_external` is US-ASCII and `CSV.read` on the Cyrillic `city.csv` raises `CSV::InvalidEncodingError`, failing every geocoding message. The official Ruby Docker images set `LANG=C.UTF-8` for this reason. |
| `channel.ack` in `auth`'s consumer | It subscribed with `manual_ack: true` and never acknowledged, so the `auth` queue grew one unacked message per request. This is slightly beyond "fix only blockers", but queue depth is the main signal used to validate the async path, and an ever-growing backlog makes it useless. Revert by dropping the `channel.ack` line and restoring `\|_, properties, payload\|`. |

## Known gaps

No health checks; no retries, backoff or circuit breaking; no idempotency on either
message handler (a redelivered `geocoding` message re-geocodes and re-PUTs); no message
schemas; no contract tests, and zero tests on `ads` — the service that orchestrates
every cross-service call. Service-to-service auth is a static shared secret compared
with `==`. The `geocoder` queue consumer lacks the `Geocoder::NotFound` guard its HTTP
route has. `ads`'s `consumer_channel` would pass a String where Bunny needs an Integer,
but nothing ever calls it.

`POST /api/v1/ads` with missing fields returns **500**, not 400: `dry-initializer` raises
`KeyError: option 'description' is required` before any ActiveRecord validation runs, and
nothing rescues it. The `error_response(..., 400)` branch in `ads_controller.rb` only fires
for model validation failures, which missing params never reach.

`ApplicationLoader#require_dir` globs with `Dir[]` and does not sort, so boot order is
filesystem-dependent in `auth` and `geocoder`. One instance of that bit us and is fixed
explicitly; the loader itself is still non-deterministic. Sorting the glob would make
boots reproducible, but note it would deterministically load `api_errors.rb` before
`validations.rb`, so the explicit `require_relative` is needed either way.
