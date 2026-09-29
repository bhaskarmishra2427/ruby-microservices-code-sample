// Drives every HTTP endpoint on all three services, so IAST has requests to replay
// on each one.
//
// ads-flow.js is a load test: it only sends HTTP to ads, gives auth a single
// sign_in in setup(), and never touches geocoder over HTTP at all (in the async
// topology geocoder only consumes from the queue and calls outward). That is why
// IAST findings appear for ruby-ms-ads and nothing else. This script exists purely
// for endpoint coverage.
//
//   k6 run loadtest/iast-surface.js
import http from 'k6/http';
import { check, fail } from 'k6';
import { SharedArray } from 'k6/data';

const ADS = __ENV.ADS_URL || 'http://localhost:3000/api/v1';
const AUTH = __ENV.AUTH_URL || 'http://localhost:4000/api/v1';
const GEO = __ENV.GEO_URL || 'http://localhost:6000/api/v1';

// geocoder's internal route and ads' callback both authenticate with the raw
// shared secret in an AUTHORIZATION header, not a Bearer token. Must match
// GEOCODER_SECRET in dev/env.
const GEOCODER_SECRET = __ENV.GEOCODER_SECRET || 'dev-geocoder-secret';

const cities = new SharedArray('cities', () => JSON.parse(open('./cities.json')));
const JSON_HEADERS = { 'Content-Type': 'application/json' };

export const options = {
  // Low and slow on purpose. This is about breadth of endpoint coverage, not
  // throughput: IAST replays every observed request with attack payloads, so a
  // high request rate multiplies into a great deal of extra work on the box.
  vus: 2,
  duration: __ENV.DURATION || '120s',
  thresholds: {
    // Deliberately loose. Some of these calls are expected to fail (duplicate
    // sign_up returns 422), and IAST's own replays are malformed by design, so a
    // clean error rate is not the goal. This ceiling only catches a service
    // falling over entirely.
    http_req_failed: ['rate<0.5'],
  },
};

function randomCity() {
  return cities[Math.floor(Math.random() * cities.length)];
}

export function setup() {
  const login = http.post(
    `${AUTH}/sign_in`,
    JSON.stringify({ email: 'tom@gmail.com', password: 'qwerty123' }),
    { headers: JSON_HEADERS },
  );
  if (login.status !== 201) fail(`sign_in failed (${login.status}): ${login.body}`);

  const token = login.json('meta.token');
  if (!token) fail('sign_in returned no token');
  return { token };
}

export default function (data) {
  const bearer = { ...JSON_HEADERS, Authorization: `Bearer ${data.token}` };

  // ---------------- auth :4000 ----------------
  // Unique email per iteration: a duplicate short-circuits to 422 and gives IAST
  // less of the handler to explore.
  http.post(
    `${AUTH}/sign_up`,
    JSON.stringify({
      name: `iast-${__VU}-${__ITER}`,
      email: `iast-${__VU}-${__ITER}-${Date.now()}@example.com`,
      password: 'hunter2pass',
    }),
    { headers: JSON_HEADERS, tags: { name: 'auth_sign_up' } },
  );

  http.post(
    `${AUTH}/sign_in`,
    JSON.stringify({ email: 'tom@gmail.com', password: 'qwerty123' }),
    { headers: JSON_HEADERS, tags: { name: 'auth_sign_in' } },
  );

  http.get(`${AUTH}/auth`, { headers: bearer, tags: { name: 'auth_verify' } });

  // ---------------- geocoder :6000 ----------------
  // The synchronous HTTP route, which the async topology never exercises. Unlike
  // the queue consumer this one guards an unknown city with a 404, so IAST
  // mutating the city parameter here is safe.
  http.post(`${GEO}/geocoder?city=${encodeURIComponent(randomCity())}`, null, {
    headers: { AUTHORIZATION: GEOCODER_SECRET },
    tags: { name: 'geocoder_lookup' },
  });

  // ---------------- ads :3000 ----------------
  const created = http.post(
    `${ADS}/ads`,
    JSON.stringify({
      ad: {
        title: `iast-${__VU}-${__ITER}`,
        description: 'iast surface',
        city: randomCity(),
      },
    }),
    { headers: bearer, tags: { name: 'ads_create' } },
  );

  check(created, { 'ads_create 200': (r) => r.status === 200 });

  http.get(`${ADS}/ads`, { tags: { name: 'ads_list' } });

  // The internal coordinate callback, normally only ever called by geocoder.
  // Guarded because a timed-out request has a null body and r.json() throws.
  if (created.status === 200 && created.body) {
    let id = null;
    try {
      id = created.json('data.id');
    } catch (_) {
      id = null;
    }
    if (id) {
      http.put(`${ADS}/ads/${id}?lat=55.75&lon=37.61`, null, {
        headers: { AUTHORIZATION: GEOCODER_SECRET },
        tags: { name: 'ads_update_coords' },
      });
    }
  }
}
