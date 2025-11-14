import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

// Load test data
const tokens = new SharedArray('tokens', function() {
  return JSON.parse(open('../fixtures/tokens.json'));
});

const users = new SharedArray('users', function() {
  return JSON.parse(open('../fixtures/users.json'));
});

// Configuration
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000/challenge';
const NAMESPACE = __ENV.NAMESPACE || 'test';

// Test parameters
const WARMUP_DURATION = '2m';        // 2 minutes warm-up
const RAMPUP_DURATION = '3m';        // 3 minutes ramp-up
const SUSTAINED_DURATION = '5m';     // 5 minutes sustained load
const TOTAL_DURATION = '10m';        // 10 minutes total

// Load levels
const WARMUP_START_RPS = 10;         // Start with 10 req/s
const WARMUP_END_RPS = 50;           // Warm up to 50 req/s
const RAMPUP_END_RPS = 300;          // Ramp up to target 300 req/s
const SUSTAINED_RPS = 300;           // Sustain at 300 req/s

export let options = {
  scenarios: {
    // Phase 1: Warm-up (0-2min, 10→50 RPS)
    // Purpose: Allow service to initialize connection pool, warm up caches, stabilize
    warmup_phase: {
      exec: 'initializeEndpoint',
      executor: 'ramping-arrival-rate',
      startRate: WARMUP_START_RPS,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 500,
      stages: [
        { duration: WARMUP_DURATION, target: WARMUP_END_RPS },
      ],
      tags: { phase: 'warmup' },
    },

    // Phase 2: Ramp-up (2-5min, 50→300 RPS)
    // Purpose: Gradually increase load to target RPS, observe performance degradation
    rampup_phase: {
      exec: 'initializeEndpoint',
      executor: 'ramping-arrival-rate',
      startRate: WARMUP_END_RPS,
      timeUnit: '1s',
      preAllocatedVUs: 500,
      maxVUs: 1000,
      startTime: WARMUP_DURATION,
      stages: [
        { duration: RAMPUP_DURATION, target: RAMPUP_END_RPS },
      ],
      tags: { phase: 'rampup' },
    },

    // Phase 3: Sustained load (5-10min, 300 RPS)
    // Purpose: Measure steady-state performance, profile at 7-minute mark
    sustained_phase: {
      exec: 'initializeEndpoint',
      executor: 'constant-arrival-rate',
      rate: SUSTAINED_RPS,
      timeUnit: '1s',
      duration: SUSTAINED_DURATION,
      startTime: '5m',  // Start after warmup + rampup
      preAllocatedVUs: 500,
      maxVUs: 1000,
      tags: { phase: 'sustained' },
    },
  },

  thresholds: {
    // Overall thresholds
    'http_req_duration': ['p(95)<100', 'p(99)<200'],
    'http_req_duration{phase:warmup}': ['p(95)<100'],
    'http_req_duration{phase:rampup}': ['p(95)<100'],
    'http_req_duration{phase:sustained}': ['p(95)<100', 'p(99)<200'],
    'http_req_failed': ['rate<0.01'],  // Less than 1% failure rate
    'checks': ['rate>0.99'],           // 99% success rate
  },
};

// ============================================================================
// Helper Functions
// ============================================================================

function createHeaders(user, token) {
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Mock-User-Id': user.id,  // Mock auth header for load testing
  };
}

// ============================================================================
// Main Test Function: Initialize Endpoint
// ============================================================================

export function initializeEndpoint() {
  const userIndex = Math.floor(Math.random() * users.length);
  const user = users[userIndex];
  const token = tokens[userIndex];

  const resp = http.post(
    `${BASE_URL}/v1/challenges/initialize`,
    '{}',
    {
      headers: createHeaders(user, token),
      tags: {
        endpoint: 'initialize',
      },
    }
  );

  const success = check(resp, {
    'status is 200': (r) => r.status === 200,
    'response has assignedGoals': (r) => {
      if (r.status !== 200) return false;
      try {
        const body = JSON.parse(r.body);
        return body.assignedGoals !== undefined;
      } catch (e) {
        return false;
      }
    },
    'response time < 200ms': (r) => r.timings.duration < 200,
    'response time < 1s': (r) => r.timings.duration < 1000,
  });

  // Log slow requests for debugging
  if (resp.timings.duration > 1000) {
    console.warn(`SLOW REQUEST: ${resp.timings.duration.toFixed(0)}ms - User: ${user.id} - Status: ${resp.status}`);
  }

  // Log errors
  if (resp.status !== 200) {
    console.error(`FAILED REQUEST: Status ${resp.status} - User: ${user.id} - Body: ${resp.body.substring(0, 200)}`);
  }
}

// ============================================================================
// Setup and Teardown
// ============================================================================

export function setup() {
  console.log('');
  console.log('=== Initialize Endpoint Load Test ===');
  console.log(`Base URL: ${BASE_URL}`);
  console.log(`Users: ${users.length}`);
  console.log('');
  console.log('Test Plan:');
  console.log(`  Phase 1 (Warm-up):  0-2min  | ${WARMUP_START_RPS}→${WARMUP_END_RPS} RPS (ramping)`);
  console.log(`  Phase 2 (Ramp-up):  2-5min  | ${WARMUP_END_RPS}→${RAMPUP_END_RPS} RPS (ramping)`);
  console.log(`  Phase 3 (Sustained): 5-10min | ${SUSTAINED_RPS} RPS (constant)`);
  console.log('');
  console.log('Thresholds:');
  console.log('  - p95 latency: <100ms');
  console.log('  - p99 latency: <200ms');
  console.log('  - Failure rate: <1%');
  console.log('');
  console.log('Monitor script will profile at 7-minute mark (mid-sustained phase)');
  console.log('');
  console.log('Starting test...');
  console.log('');

  return {
    startTime: new Date().toISOString(),
  };
}

export function teardown(data) {
  console.log('');
  console.log('=== Initialize Endpoint Load Test Complete ===');
  console.log(`Start time: ${data.startTime}`);
  console.log(`End time: ${new Date().toISOString()}`);
  console.log('');
  console.log('Next Steps:');
  console.log('1. Check k6 summary for performance metrics');
  console.log('2. Review pprof profiles captured at 7-minute mark');
  console.log('3. Run SQL benchmark to compare:');
  console.log('   docker exec -i challenge-postgres psql -U postgres -d challenge_db < tests/loadtest/sql/quick_benchmark.sql');
  console.log('');
  console.log('4. Check for slow requests in logs:');
  console.log('   docker logs challenge-service --tail=500 2>&1 | grep -i "slow\\|error\\|failed"');
  console.log('');
  console.log('5. Verify database state:');
  console.log('   docker exec challenge-postgres psql -U postgres -d challenge_db -c "');
  console.log('   SELECT COUNT(*) as total_rows, COUNT(DISTINCT user_id) as unique_users');
  console.log('   FROM user_goal_progress;"');
  console.log('');
}
