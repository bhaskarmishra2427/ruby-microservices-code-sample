# Runbook

Deploy and run this three-service Ruby system, then instrument it with New Relic's
eBPF agent under active load.

- **Target deployment:** Ubuntu 24.04 VM — [Part 1–7](#part-1--transfer-the-code) below.
- **Local macOS development:** [dev/README.md](dev/README.md).
- **VM reference detail:** [vm/README.md](vm/README.md).
- **Load test results and analysis:** [loadtest/results/README.md](loadtest/results/README.md).

---

## What you are deploying

```
                POST /api/v1/ads
                       │
                       ▼
                 ┌───────────┐   AMQP RPC (queue: auth, amq.rabbitmq.reply-to)   ┌────────┐
                 │    ads    │ ◄──────────────────────────────────────────────►  │  auth  │
                 │   :3000   │                                                   │ :4000  │
                 └───────────┘                                                   └────────┘
                       │
                       │ AMQP publish (queue: geocoding, durable)
                       ▼
                 ┌───────────┐
                 │ geocoder  │
                 │   :6000   │
                 └───────────┘
                       │
                       │ PUT /api/v1/ads/:id   (no queue alternative for this hop)
                       ▼
                 ┌───────────┐
                 │    ads    │
                 └───────────┘
```

Three independently-deployed Sinatra services, each owning its own data:

| Service | Port | Datastore | Role |
|---|---|---|---|
| `ads` | 3000 | `ms-ads-production` (ActiveRecord) | Public API, orchestrates the other two |
| `auth` | 4000 | `ms-auth` (Sequel) | JWT issue/verify, answers AMQP RPC |
| `geocoder` | 6000 | none — reads `db/data/city.csv` | City → lat/lon, AMQP consumer |

Topology is selected by environment variable, not code. This runbook deploys the **async**
path: `AUTH_METHOD=sync_rpc`, `GEOCODE_METHOD=async_publish_to_queue`.

**Prerequisites on the VM:** Ubuntu 24.04 LTS, kernel **5.8–7.1** (24.04 ships 6.8), x86_64
or arm64, ≥2 GB RAM, SSH inbound, 443 outbound. Use a **non-burstable** instance type
(`c7i.xlarge`, `m7i.xlarge`) — a burstable `t3` exhausts CPU credits mid-load-test and
throttles, silently corrupting your measurements.

---

## Part 1 — Transfer the code

Either method works. Run from the repo root on your Mac.

**Option A — git** (preferred; `dev/env` is gitignored so no secrets travel):

```bash
git add -A
git commit -m "Port to Ruby 3.3, add load test and VM provisioning"
git push                       # to your own remote
```

Then on the VM:

```bash
git clone <your-remote-url> ~/ruby-microservices
cd ~/ruby-microservices
```

**Option B — rsync** (no remote needed):

```bash
rsync -av --delete \
  --exclude '.git' --exclude 'dev/log' --exclude 'dev/tmp' \
  ./ ubuntu@<VM_IP>:~/ruby-microservices/
```

> rsync **will** copy `dev/env` if it exists locally, including its secrets. That is
> convenient but deliberate — add `--exclude 'dev/env'` if you would rather generate it
> fresh on the VM.

---

## Part 2 — Provision the host

```bash
cd ~/ruby-microservices
cp dev/env.example dev/env        # must exist BEFORE provisioning
vm/provision.sh
```

`dev/env` comes first because `provision.sh` reads `PG_USER` and `PG_PASSWORD` from it to
create the database role — this stops the role from drifting from what the services
authenticate with. Edit `dev/env` now if you want non-default secrets.

`provision.sh` is idempotent and does, in order:

1. **Kernel preflight** — aborts unless `uname -r` is within 5.8–7.1. The *upper* bound is
   real: the eBPF agent will not run above 7.1.
2. apt packages — Ruby build deps, PostgreSQL, RabbitMQ, plus `lsof` and `jq` which Ubuntu
   cloud images omit.
3. `locale-gen en_US.UTF-8` — mandatory, see [Part 8](#part-8--troubleshooting).
4. rbenv + ruby-build, then Ruby **3.3.12** (a few minutes to compile), and asserts the
   socket extension actually built.
5. PostgreSQL role `ads` plus `ms-ads-production` and `ms-auth`, both **owned by** `ads`.
6. RabbitMQ with the management plugin.
7. k6.

Expected tail:

```
Provisioning complete.

  ruby      3.3.12
  postgres  16.x
  rabbitmq  3.12.x
  k6        k6 v0.5x.x
  kernel    6.8.0-xx-generic
```

Open a new shell (or `source ~/.bashrc`) so `rbenv` is on your `PATH`.

---

## Part 3 — Install gems and build the databases

```bash
cd ~/ruby-microservices
dev/setup.sh
```

This bundles all three services, runs `db:schema:load` for `ads`, then `db:migrate` and
`db:seed` for `auth`. Seeds three users, all with password `qwerty123`:
`tom@gmail.com`, `logan@gmail.com`, `jack@gmail.com`.

Verify:

```bash
psql -U ads -h localhost -d ms-ads-production -c '\dt'      # expect: ads
psql -U ads -h localhost -d ms-auth -c 'SELECT email FROM users;'
```

> `db:migrate` re-dumps `auth/db/schema.rb` as a side effect, and because it runs before
> `db:seed` the dump omits `sequel-seed`'s `schema_seeds` table. The table is still created
> at seed time. Discard the spurious diff with `git checkout auth/db/schema.rb`.

---

## Part 4 — Run the services

```bash
vm/install-systemd.sh
```

Renders the three unit templates with your paths, installs `dev/env` to
`/etc/newrelic-ms/env` (root-owned, `0600`), then enables and starts everything. Startup
order matters and the units enforce it: `auth` and `geocoder` must come up before `ads`,
because both AMQP consumers load as initializers *inside* their own web processes and must
be subscribed before `ads` can issue an RPC call or publish a job.

```bash
systemctl status ms-ads ms-auth ms-geocoder
journalctl -u ms-ads -n 30 --no-pager | jq .     # all three log JSON to journald
```

After editing `dev/env`, re-run `vm/install-systemd.sh` (it re-copies the file), then
`sudo systemctl restart ms-ads ms-auth ms-geocoder`.

> `dev/start.sh` also works on the VM for quick iteration, but do **not** run it alongside
> the systemd units — they contend for the same ports. `install-systemd.sh` calls
> `dev/stop.sh` first for this reason.

---

## Part 5 — Verify all four hops

```bash
sudo rabbitmqctl list_queues name messages messages_unacknowledged consumers
```

Expect `auth` and `geocoding`, each with 1 consumer, both draining to 0.

```bash
TOKEN=$(curl -s -X POST localhost:4000/api/v1/sign_in \
  -H 'Content-Type: application/json' \
  -d '{"email":"tom@gmail.com","password":"qwerty123"}' | jq -r .meta.token)

curl -s -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"test","description":"test","city":"Майкоп"}}' | jq .

sleep 2   # lat/lon arrive asynchronously, via queue then HTTP callback
curl -s localhost:3000/api/v1/ads -H "Authorization: Bearer $TOKEN" | jq '.data[0].attributes'
```

A populated `lat`/`lon` proves the whole chain: HTTP in → AMQP RPC to `auth` → AMQP publish
to `geocoder` → HTTP callback to `ads`.

```json
{ "title": "test", "description": "test", "city": "Майкоп", "lat": "44.61", "lon": "40.1" }
```

**City names must come from `geocoder/db/data/city.csv`** — they are Russian, in Cyrillic.
All 1,093 valid names are in `loadtest/cities.json`.

---

## Part 6 — Install the New Relic eBPF agent

This step cannot be scripted: the install command embeds an account user key.

1. In New Relic: **Integration & Agents → eBPF Agent**.
2. Installation method: **On a host**.
3. Generate or pick a user key, name the deployment.
4. Run the generated command on the VM (installs a Debian package).
5. Verify:

```bash
sudo systemctl status newrelic-ebpf-agent
```

No application changes are needed — that is the point of eBPF instrumentation. Services
should appear in New Relic on their own.

### What the agent will and will not show

The agent recognises AMQP (`protocol.name: amqp`) and collects connection and network
telemetry for it, but **segment linking is unsupported for AMQP** (also Kafka, Cassandra):

| Hop | Transport | eBPF result |
|---|---|---|
| client → `ads` | HTTP | traced and linked |
| `ads` → `auth` | AMQP RPC | network telemetry only, **not linked** |
| `ads` → `geocoder` | AMQP queue | network telemetry only, **not linked** |
| `geocoder` → `ads` | HTTP callback | traced and linked |
| `ads`/`auth` → PostgreSQL | postgresql | traced and linked |

So no single eBPF trace spans the queue hops. This is a real limitation, not a
misconfiguration, and it is the most interesting result here: it is the honest answer to
what zero-code eBPF instrumentation can tell you about a queue-based architecture.

Linked traces through RabbitMQ need the Ruby APM agent, which **does** auto-instrument
Bunny (queue operations appear as `Put`/`Take`) with no manual `MessageBroker` segments.
The two are complementary.

---

## Part 7 — Load test and measure agent overhead

```bash
cd ~/ruby-microservices
k6 run loadtest/ads-flow.js
```

Profile: ramp 0→20 VUs over 1 min, hold 20 for 5 min, ramp to 50 for 2 min, ramp down
(~9 min). `setup()` signs in once and shares the JWT across all VUs — signing in per
iteration would make bcrypt the bottleneck — then runs a preflight that creates one ad and
waits for its coordinates, so a broken chain fails in seconds rather than after ten minutes.

To quantify what the agent costs, run the identical profile twice:

```bash
sudo systemctl stop newrelic-ebpf-agent
k6 run --summary-export=loadtest/results/vm-agent-off.json loadtest/ads-flow.js

sudo systemctl start newrelic-ebpf-agent
k6 run --summary-export=loadtest/results/vm-agent-on.json loadtest/ads-flow.js
```

The macOS numbers in [loadtest/results/README.md](loadtest/results/README.md) are **not**
comparable across hosts — establish a fresh baseline on this box.

Optionally reproduce the tuning finding on the real target by reverting the two values in
`dev/env` (`PUMA_MAX_THREADS=5`) and `auth/config/settings.yml` (`consumer_pool: 1`), then
re-running. On macOS that regressed p95 from 27 ms to 158 ms and introduced 60-second
timeouts.

---

## Part 8 — Troubleshooting

Each of these actually occurred while getting the stack running; the signatures are worth
recognising.

| Symptom | Cause |
|---|---|
| `geocoding` queue backlog grows, messages unacked | A city not in `city.csv`. `Geocoder::FindService` returns `nil`, the consumer passes it to `coords[0]`, raises `NoMethodError`, never acks. Use `loadtest/cities.json`. |
| `auth` **unacked** count grows one per request | The `channel.ack` in `auth/config/initializers/consumer.rb` is missing. |
| `CSV::InvalidEncodingError: Invalid byte sequence in US-ASCII` | No UTF-8 locale, so Ruby's `default_external` is US-ASCII and `city.csv` is Cyrillic. `LANG`/`LC_ALL` must reach the process — they are in `dev/env`, which systemd loads via `EnvironmentFile`. |
| Ad created but `lat`/`lon` stay `null` | `GEOCODER_SECRET` mismatch: `geocoder` sends it on the callback, `ads` compares against it. Every callback 403s silently. It is one value in `dev/env`, shared. |
| Every request 403s | Auth RPC timing out. Check `auth` is running and consuming; `AUTH_RPC_TIMEOUT` (default 5s) bounds the wait and returns 403 rather than hanging a thread. |
| `{"error":"Failed to parse body as JSON"}` on every POST | `json` 3.x removed the `create_additions:` keyword that `Rack::JSONBodyParser` still passes. `json` is pinned to `~> 2.7` in all three Gemfiles — do not unpin. |
| Boot fails: `uninitialized constant ApiErrors::Validations` | `ApplicationLoader` globs with `Dir[]`, whose order is not guaranteed. Fixed by an explicit `require_relative` in `auth/app/helpers/api_errors.rb`. |
| Model attributes all `nil`, no error raised | Ruby 3 keyword separation. `BasicService.call(*args)` collected keywords into a positional Hash that `dry-initializer` ignored. Fixed in both services' `basic_service.rb`. |
| Bimodal latency: healthy median, 60-second tail | Puma thread-pool saturation, not slow work. Every `POST /ads` holds a thread for a blocking AMQP RPC, and `geocoder`'s callbacks land in the same pool. See `PUMA_MAX_THREADS`. |

Useful commands:

```bash
journalctl -u ms-ads -f | jq .
sudo rabbitmqctl list_queues name messages messages_unacknowledged consumers
curl -s localhost:6000/metrics | grep geocoding_process_time   # geocoder's own Prometheus histogram
sudo rabbitmqctl purge_queue geocoding                          # drain poisoned messages
psql -U ads -h localhost -d ms-ads-production -c 'SELECT count(*), count(lat) FROM ads;'
```

---

## API reference — using the app

Nine endpoints across three services. Only two are meant for a human to call; the rest
are either internal or infrastructure.

| Method | Endpoint | Auth | Purpose |
|---|---|---|---|
| `POST` | `:4000/api/v1/sign_up` | none | Create a user. `201` empty body, or `422`. |
| `POST` | `:4000/api/v1/sign_in` | none | Exchange credentials for a JWT. `201 {meta:{token}}`, or `401`. |
| `GET` | `:4000/api/v1/auth` | `Bearer <jwt>` | Resolve a token to a user. `200 {meta:{user_id}}`, or `403`. |
| `GET` | `:3000/api/v1/ads` | **none** | List ads, 25 per page, `?page=N`. |
| `POST` | `:3000/api/v1/ads` | `Bearer <jwt>` | Create an ad. Triggers the whole async chain. `403` on a bad token. |
| `PUT` | `:3000/api/v1/ads/:id` | `GEOCODER_SECRET` | **Internal.** The geocoder's coordinate callback. |
| `POST` | `:6000/api/v1/geocoder?city=X` | `GEOCODER_SECRET` | **Internal.** Synchronous geocode. `404` if the city is unknown. |
| `GET` | `:6000/metrics` | none | Prometheus metrics, incl. `geocoding_process_time`. |

Note `GET /api/v1/ads` takes no auth — reads are public in this sample. The two internal
endpoints authenticate with the raw shared secret in an `AUTHORIZATION` header, **not** a
`Bearer` token.

### A full walkthrough

```bash
# 1. Create your own user (or skip and use a seeded one)
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:4000/api/v1/sign_up \
  -H 'Content-Type: application/json' \
  -d '{"name":"Bhaskar","email":"b@example.com","password":"hunter2pass"}'
# -> 201

# 2. Sign in for a JWT. Seeded users: tom@ / logan@ / jack@gmail.com, all qwerty123
TOKEN=$(curl -s -X POST localhost:4000/api/v1/sign_in \
  -H 'Content-Type: application/json' \
  -d '{"email":"b@example.com","password":"hunter2pass"}' | jq -r .meta.token)
echo "$TOKEN"

# 3. Prove the token resolves, talking to auth directly over HTTP
curl -s localhost:4000/api/v1/auth -H "Authorization: Bearer $TOKEN" | jq .
# -> {"meta":{"user_id":4}}

# 4. Create an ad. This is the interesting call: ads verifies the token via an AMQP
#    RPC to auth, then publishes a geocoding job and returns immediately.
curl -s -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"Flat in Kazan","description":"2 rooms","city":"Казань"}}' | jq .
# -> lat and lon are null here; geocoding has not happened yet

# 5. A moment later they are filled in, by geocoder calling back into ads over HTTP
sleep 2
curl -s localhost:3000/api/v1/ads | jq '.data[0]'
# -> "lat":"55.79","lon":"49.11"

# 6. Pagination
curl -s 'localhost:3000/api/v1/ads?page=2' | jq '.links'
```

**City names must come from `geocoder/db/data/city.csv`** — they are Russian, in Cyrillic.
All 1,093 valid names are in `loadtest/cities.json`:

```bash
jq -r '.[0:10][]' loadtest/cities.json          # sample ten
jq -r '.[]' loadtest/cities.json | shuf -n 1    # pick a random one
```

### Watching the hops happen

The most useful way to understand the system is to tail all three services while creating
an ad. In one terminal:

```bash
journalctl -u ms-ads -u ms-auth -u ms-geocoder -f -o cat | jq -c 'select(.msg) | {svc:.service.name, msg, request_id}'
```

Create an ad in another, and you will see the chain in order — `calling rpc auth` from
`ads`, `authenticate user` from `auth`, `sending data to geocoder via RabbitMQ` from `ads`,
`geocoded coordinates` from `geocoder`, then `updating ad coordinates` back in `ads`. The
`request_id` is the same across all five lines; that correlation was already in the repo
and is what makes the async path traceable at all.

Watch the queues drain in real time:

```bash
watch -n1 'sudo rabbitmqctl list_queues name messages messages_unacknowledged consumers'
```

And the geocoder's own histogram:

```bash
curl -s localhost:6000/metrics | grep geocoding_process_time_sum
```

### Exercising the services in isolation

Useful when something is broken and you want to know which hop:

```bash
# geocoder alone, no queue involved. Needs the shared secret, not a Bearer token.
SECRET=$(grep '^GEOCODER_SECRET=' dev/env | cut -d= -f2)
curl -s -X POST "localhost:6000/api/v1/geocoder?city=Казань" -H "AUTHORIZATION: $SECRET" | jq .
# -> {"meta":{"lat":55.7943584,"lon":49.1114975}}

# an unknown city, to see the 404 the HTTP route returns
curl -s -X POST "localhost:6000/api/v1/geocoder?city=Atlantis" -H "AUTHORIZATION: $SECRET" | jq .
```

Note the discrepancy: the synchronous HTTP route guards a missing city with a `404`, but the
queue consumer has no such guard and crashes instead. That asymmetry is in
[Part 8](#part-8--troubleshooting) and is why the load generator only uses real city names.

### Deliberate failure cases

```bash
# bad token -> 403, raised by the Auth helper after the RPC returns nothing
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer garbage' \
  -d '{"ad":{"title":"x","description":"x","city":"Казань"}}'
# -> 403

# missing required fields -> 500, NOT a clean 400. dry-initializer raises
# `KeyError: CreateAdService::Ad: option 'description' is required` before any
# ActiveRecord validation runs, and nothing rescues it. The 400 path in
# ads_controller.rb only fires for model validation failures, which missing
# params never reach. An unfixed gap in the original sample, listed in Known gaps.
curl -s -w ' [HTTP %{http_code}]\n' -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"only a title"}}'

# stop auth, then create an ad: the RPC times out after AUTH_RPC_TIMEOUT and returns
# 403 rather than hanging a Puma thread forever
sudo systemctl stop ms-auth
time curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"x","description":"x","city":"Казань"}}'
# -> 403 after ~5s
sudo systemctl start ms-auth
```

That last one is worth running once: without the timeout fix this request would never
return, and under load it would exhaust the thread pool.

---

## Appendix — what changed from the original repo

The upstream sample was written for Ruby 2.6.6 in 2021 and last touched 2022-01-10. Twelve
changes were needed to make it run at all on a current toolchain — Ruby 3.3.12, an
ActiveRecord major bump, three gem incompatibilities, two Ruby 3 kwargs breakages, a
load-order bug and a locale trap. All are tabulated with rationale in
[dev/README.md](dev/README.md#what-had-to-change-to-run-on-ruby-33--macos-26).

Known gaps deliberately left in place — no health checks, no retries or circuit breaking,
no idempotency on either message handler, no message schemas, no contract tests, and zero
tests on `ads` (the service orchestrating every cross-service call) — are listed in
[dev/README.md](dev/README.md#known-gaps). They are the gap analysis, not oversights.
