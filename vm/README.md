# Running on an Ubuntu VM with the New Relic eBPF agent

macOS has no eBPF support, so the agent needs a Linux host. This directory provisions
one and runs the three services under systemd. No containers, no Kubernetes — the
eBPF agent's host mode works on a plain VM.

For local macOS development see [dev/README.md](../dev/README.md); the application code
is identical either way.

## Host requirements

| | |
|---|---|
| OS | Ubuntu 24.04 LTS (20.04+ supported) |
| Arch | x86_64 or arm64 — both fully supported |
| **Kernel** | **5.8 – 7.1 inclusive.** Ubuntu 24.04 ships 6.8. |
| RAM | ≥ 2 GB for the agent; 8 GB+ comfortable with everything on one box |
| Inbound | SSH only (k6 runs on the box) |
| Outbound | 443 to New Relic |

Note the kernel **upper** bound — the agent will not function above 7.1.
`vm/provision.sh` checks this first and aborts rather than let you discover it later.

**Pick a non-burstable instance type** (`c7i.xlarge`, `m7i.xlarge`, or similar). A
burstable `t3`/`t4g` will exhaust CPU credits partway through a 9-minute load run and
throttle, silently corrupting the measurements you are there to collect.

## Setup

Get the repo onto the box, then:

```bash
cp dev/env.example dev/env     # edit if you want non-default secrets
vm/provision.sh                # packages, locale, Ruby 3.3.12, Postgres, RabbitMQ, k6
dev/setup.sh                   # bundle install x3, schema load, seed users
vm/install-systemd.sh          # render + start the three units
```

`vm/provision.sh` is idempotent, so re-running it is safe. It deliberately does **not**
build YJIT (no `rustc`), keeping results comparable with the non-YJIT macOS baseline.

### Then install the eBPF agent

This step cannot be scripted here: the install command embeds an account user key.

1. In New Relic, go to **Integration & Agents → eBPF Agent**.
2. Choose **On a host** as the installation method.
3. Generate or select a user key and give the deployment a name.
4. Copy the generated command and run it on the VM. It installs a Debian package.
5. Verify:

```bash
sudo systemctl status newrelic-ebpf-agent
```

The agent needs root, and requires no changes to the application — that is the point
of eBPF instrumentation.

## Verifying the deployment

```bash
systemctl status ms-ads ms-auth ms-geocoder
journalctl -u ms-auth -n 50 --no-pager | jq .
sudo rabbitmqctl list_queues name messages messages_unacknowledged
```

Both `auth` and `geocoding` should show a consumer and drain to 0. Two failure
signatures worth knowing, because both bit us during the macOS build:

- **`geocoding` backlog grows** — a city not present in `geocoder/db/data/city.csv`.
  `Geocoder::FindService` returns `nil`, the consumer passes it into `coords[0]`, raises
  `NoMethodError`, and never acks. Use cities from `loadtest/cities.json`.
- **`auth` *unacked* count grows** — the `channel.ack` in
  `auth/config/initializers/consumer.rb` is missing.

End-to-end check, all four hops:

```bash
TOKEN=$(curl -s -X POST localhost:4000/api/v1/sign_in \
  -H 'Content-Type: application/json' \
  -d '{"email":"tom@gmail.com","password":"qwerty123"}' | jq -r .meta.token)

curl -s -X POST localhost:3000/api/v1/ads \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"ad":{"title":"test","description":"test","city":"Майкоп"}}' | jq .

sleep 2   # lat/lon arrive asynchronously via the geocoder -> ads callback
curl -s localhost:3000/api/v1/ads -H "Authorization: Bearer $TOKEN" | jq '.data[0]'
```

## Load test and measuring agent overhead

```bash
k6 run loadtest/ads-flow.js
```

The script's `setup()` runs a preflight that creates one ad and waits for its
coordinates, so a broken async chain fails in seconds rather than after ten minutes.

To quantify what the agent costs, run the same profile twice:

```bash
sudo systemctl stop newrelic-ebpf-agent
k6 run --summary-export=loadtest/results/vm-agent-off.json loadtest/ads-flow.js

sudo systemctl start newrelic-ebpf-agent
k6 run --summary-export=loadtest/results/vm-agent-on.json loadtest/ads-flow.js
```

The macOS numbers in [loadtest/results/README.md](../loadtest/results/README.md) are
**not** comparable across hosts — re-establish a baseline on this box.

## What eBPF will and will not show you

The agent recognises AMQP (`protocol.name: amqp`) and collects connection and network
telemetry for it, **but segment linking is explicitly unsupported for AMQP** (also Kafka
and Cassandra). On this deployment's async topology that means:

| Hop | Transport | eBPF result |
|---|---|---|
| client → `ads` | HTTP | traced and linked |
| `ads` → `auth` | AMQP RPC | network telemetry only, **not linked** |
| `ads` → `geocoder` | AMQP queue | network telemetry only, **not linked** |
| `geocoder` → `ads` | HTTP callback | traced and linked |
| `ads`/`auth` → PostgreSQL | postgresql | traced and linked |

So there is no single eBPF trace spanning the queue hops. This is a genuine finding
rather than a misconfiguration: it is the honest answer to what zero-code eBPF
instrumentation can tell you about a queue-based architecture.

Connected traces across RabbitMQ require the Ruby APM agent, which **does**
auto-instrument Bunny (reporting queue operations as `Put`/`Take`) with no manual
`MessageBroker` segments. The two approaches are complementary: eBPF gives zero-code
discovery plus HTTP/database/network visibility, the language agent gives the linked
trace through the broker.

## Environment differences from the validated macOS run

| | macOS (tested) | Ubuntu 24.04 |
|---|---|---|
| RabbitMQ | 4.3.6 (brew) | 3.12.x (apt) |
| PostgreSQL | 16 (brew) | 16 (apt) |
| Ruby | 3.3.12 (rbenv) | 3.3.12 (rbenv) |
| Process manager | `dev/start.sh` | systemd |

AMQP 0-9-1 is unchanged between RabbitMQ 3.12 and 4.3 and Bunny 2.24 supports both, so
no code impact is expected — but this is a real difference from the environment the
stack was validated in, and belongs in any writeup.

`dev/start.sh` still works here for quick iteration. Do not run it alongside the
systemd units; they contend for the same ports. `vm/install-systemd.sh` calls
`dev/stop.sh` first for that reason.

## Secrets

`dev/env` is installed to `/etc/newrelic-ms/env` as root-owned `0600`. It ships
throwaway values (`PG_PASSWORD=ads`, `APP_SECRET`, `GEOCODER_SECRET`) which are
acceptable on an SSH-only box with no inbound database port. Change them if the host
becomes long-lived or gains wider network exposure. After editing `dev/env`, re-run
`vm/install-systemd.sh` and restart the units.
