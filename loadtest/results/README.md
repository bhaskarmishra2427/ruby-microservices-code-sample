# Load test results

Same code, same load profile (ramp 0→20 VUs over 1m, hold 20 for 5m, ramp to 50 for
2m, ramp down), on the async topology: `AUTH_METHOD=sync_rpc`,
`GEOCODE_METHOD=async_publish_to_queue`.

Host: Apple Silicon, Ruby 3.3.12 native arm64, PostgreSQL 16 and RabbitMQ 4.3.6 via
brew services, all three services on localhost.

## Baseline vs tuned

Two config values changed between runs:

- `ads/config/puma.rb` — max threads 5 (Puma's default) → 16
- `auth/config/settings.yml` — `rabbit_mq.consumer_pool` 1 → 8

| Metric | Baseline | Tuned | Change |
|---|---|---|---|
| `create_ad` p95 | 157.95 ms | 27.4 ms | −83% |
| `create_ad` avg | 234.28 ms | 14.84 ms | −94% |
| `create_ad` max | 60.0 s | 208 ms | timeouts eliminated |
| `http_req_failed` | 0.10% (21 of 20,239) | 0.00% (0 of 23,958) | — |
| Throughput | 37.05 req/s | 43.84 req/s | +18% |
| Iterations | 10,128 | 11,977 | +18% |
| Checks passed | 99.79% | 100.00% | — |

Machine-readable summaries: `baseline.json`, `tuned.json`.

## Why the baseline collapsed

Every `POST /api/v1/ads` holds a Puma thread for the whole duration of a blocking AMQP
RPC to `auth`. Separately, `geocoder`'s `PUT /api/v1/ads/:id` callbacks arrive in that
*same* Puma pool — roughly one callback per ad created. At Puma's default of 5 threads,
inbound creates and inbound callbacks starve each other, and behind them `auth` was
serving every RPC on a single consumer thread.

The result was a bimodal latency distribution: a healthy median (9.55 ms) alongside a
60-second tail, which is the signature of queueing for a saturated thread pool rather
than slow work. 21 requests hit k6's 60 s ceiling.

Raising both ceilings removed the tail entirely while barely moving the median — the work
itself was never slow.

## Note on absolute numbers

Throughput here is bounded by the load profile, not the system: the script sleeps 1 s per
iteration, so 50 VUs implies a ceiling near 50 iterations/s and the tuned run reached
21.9. These runs are meaningful as a *comparison*, not as a capacity measurement. To find
actual saturation, drop the `sleep(1)` and raise VUs until latency degrades.
