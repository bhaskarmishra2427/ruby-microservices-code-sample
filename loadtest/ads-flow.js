// Drives the async topology end to end:
//   ads (HTTP in) -> auth (AMQP RPC) -> geocoder (AMQP) -> ads (HTTP callback)
//
// Run with the services up (dev/start.sh):  k6 run loadtest/ads-flow.js
import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { SharedArray } from 'k6/data';

const ADS = __ENV.ADS_URL || 'http://localhost:3000/api/v1';
const AUTH = __ENV.AUTH_URL || 'http://localhost:4000/api/v1';

// Cities MUST come from geocoder/db/data/city.csv. Geocoder::FindService returns
// nil for a miss, and the queue consumer passes that straight into coords[0],
// raising NoMethodError and leaving the message unacked. Random strings would
// poison the queue on every single iteration.
const cities = new SharedArray('cities', () => JSON.parse(open('./cities.json')));

const JSON_HEADERS = { 'Content-Type': 'application/json' };

export const options = {
  stages: [
    { duration: '1m', target: 20 },
    { duration: '5m', target: 20 },
    { duration: '2m', target: 50 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:create_ad}': ['p(95)<2000'],
  },
};

function randomCity() {
  return cities[Math.floor(Math.random() * cities.length)];
}

function listLatest(token) {
  return http.get(`${ADS}/ads`, {
    headers: { Authorization: `Bearer ${token}` },
    tags: { name: 'list_ads' },
  });
}

export function setup() {
  // Sign in once and share the JWT across all VUs. Signing in per iteration
  // would make bcrypt the bottleneck and mask the path actually under test.
  const login = http.post(
    `${AUTH}/sign_in`,
    JSON.stringify({ email: 'tom@gmail.com', password: 'qwerty123' }),
    { headers: JSON_HEADERS },
  );

  if (login.status !== 201) {
    fail(`sign_in failed (${login.status}): ${login.body}`);
  }
  const token = login.json('meta.token');
  if (!token) fail('sign_in returned no token');

  // Preflight: prove the whole async chain works before spending ten minutes
  // generating load that would otherwise prove nothing. A create that succeeds
  // but never gets coordinates means the queue hop or the HTTP callback is
  // broken -- most often a GEOCODER_SECRET mismatch between ads and geocoder.
  const city = randomCity();
  const created = http.post(
    `${ADS}/ads`,
    JSON.stringify({ ad: { title: 'preflight', description: 'preflight', city } }),
    { headers: { ...JSON_HEADERS, Authorization: `Bearer ${token}` } },
  );

  if (created.status !== 200) {
    fail(`preflight create_ad failed (${created.status}): ${created.body}`);
  }
  const id = created.json('data.id');

  for (let i = 0; i < 20; i++) {
    sleep(0.5);
    const page = listLatest(token);
    const hit = (page.json('data') || []).find((d) => d.id === id);
    if (hit && hit.attributes.lat !== null && hit.attributes.lon !== null) {
      console.log(
        `preflight OK: ad ${id} ("${city}") geocoded to ` +
          `${hit.attributes.lat},${hit.attributes.lon} after ~${(i + 1) * 0.5}s`,
      );
      return { token };
    }
  }

  fail(
    `preflight: ad ${id} ("${city}") never received coordinates within 10s. ` +
      'Check the geocoding queue depth and the geocoder -> ads callback ' +
      '(GEOCODER_SECRET must match in both services).',
  );
}

export default function (data) {
  const headers = {
    ...JSON_HEADERS,
    Authorization: `Bearer ${data.token}`,
  };

  // Triggers the RPC auth call, then publishes a geocoding job to the queue.
  const created = http.post(
    `${ADS}/ads`,
    JSON.stringify({
      ad: {
        title: `load-${__VU}-${__ITER}`,
        description: 'k6 generated',
        city: randomCity(),
      },
    }),
    { headers, tags: { name: 'create_ad' } },
  );

  check(created, {
    'create_ad 200': (r) => r.status === 200,
    // A request that times out has a null body, and r.json() throws on it, so
    // guard rather than let the check itself raise.
    'create_ad returned an id': (r) => {
      if (r.status !== 200 || !r.body) return false;
      try {
        return !!r.json('data.id');
      } catch (_) {
        return false;
      }
    },
  });

  listLatest(data.token);

  sleep(1);
}

export function teardown(data) {
  // Coordinates arrive asynchronously, so give the queue a moment to drain,
  // then report how much of the most recent page actually got geocoded.
  sleep(5);

  const page = listLatest(data.token);
  const rows = page.json('data') || [];
  const done = rows.filter(
    (d) => d.attributes.lat !== null && d.attributes.lon !== null,
  ).length;

  console.log(`geocoded ${done}/${rows.length} of the most recent page`);
  if (rows.length && done < rows.length) {
    console.log(
      'A shortfall here usually means the geocoding queue is still draining, ' +
        'or messages are stuck unacked. Check: rabbitmqctl list_queues',
    );
  }
}
