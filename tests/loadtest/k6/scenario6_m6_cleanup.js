import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

// Load test data
const tokens = new SharedArray('tokens', function () {
  return JSON.parse(open('../fixtures/tokens.json'));
});

const users = new SharedArray('users', function () {
  return JSON.parse(open('../fixtures/users.json'));
});

// Configuration
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000/challenge';
const METRICS_URL = __ENV.METRICS_URL || 'http://localhost:8080/metrics';
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6566';
const TARGET_VUS = parseInt(__ENV.TARGET_VUS || '150');
const ITERATIONS = parseInt(__ENV.ITERATIONS || '120');
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '500');
const NAMESPACE = __ENV.NAMESPACE || 'test';
const ABSOLUTE_CHALLENGE_ID = 'challenge-001';

// gRPC clients
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

loginClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

// Track connection state per VU
let loginConnected = false;
let statConnected = false;

export let options = {
  scenarios: {
    // M6 cleanup validation: API user sessions (same as scenario5)
    api_load: {
      executor: 'per-vu-iterations',
      vus: TARGET_VUS,
      iterations: ITERATIONS,
      maxDuration: '30m',
      exec: 'cleanupUserSession',
    },

    // Background stat events (same as scenario5)
    event_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '30m',
      preAllocatedVUs: 1000,
      maxVUs: 1500,
      exec: 'eventLoad',
    },

    // Periodic metrics scrape to monitor cleanup goroutine
    table_monitor: {
      executor: 'constant-arrival-rate',
      rate: 1,
      duration: '30m',
      preAllocatedVUs: 1,
      maxVUs: 1,
      exec: 'monitorCleanup',
    },
  },

  thresholds: {
    // Overall API health
    'http_req_duration': ['p(95)<2000'],
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],

    // Endpoint-specific thresholds (carried from scenario5)
    'http_req_duration{endpoint:rotation_status}': ['p(95)<100'],
    'http_req_duration{endpoint:browse_challenges}': ['p(95)<500'],
    'http_req_duration{endpoint:initialize}': ['p(95)<100'],
    'http_req_duration{endpoint:batch_select}': ['p(95)<50'],
    'http_req_duration{endpoint:random_select}': ['p(95)<50'],
    'http_req_duration{endpoint:check_progress}': ['p(95)<500'],
    'http_req_duration{endpoint:claim}': ['p(95)<100'],

    // M6-specific thresholds
    'http_req_duration{endpoint:gdpr_delete}': ['p(95)<500'],
    'http_req_duration{endpoint:browse_after_delete}': ['p(95)<500'],
    'http_req_duration{endpoint:metrics_scrape}': ['p(95)<200'],

    // Event processing
    'grpc_req_duration': ['p(95)<500'],
  },
};

// ============================================================================
// M6 CLEANUP USER SESSION - Sequential Per-VU
// ============================================================================
// Same as scenario5's rotationUserSession, plus GDPR delete (10% of sessions).
// Validates that background cleanup goroutine doesn't regress API latency.
// ============================================================================

export function cleanupUserSession() {
  const token = tokens[__VU % tokens.length];
  const user = users[__VU % users.length];

  // Alternate between daily and weekly rotation challenges
  const challengeId = Math.random() < 0.7 ? 'daily-challenges' : 'weekly-challenges';

  // === STEP 1: Initialize ===
  callInitialize(user, token);
  sleep(randomBetween(1, 2));

  // === STEP 2: Browse Challenges (validate expiresAt) ===
  browseChallengesWithRotationChecks(user, token);
  sleep(randomBetween(2, 4));

  // === STEP 3: Select rotation goals (60% random, 40% batch) ===
  if (Math.random() < 0.6) {
    randomSelectRotationGoals(user, token, challengeId);
  } else {
    batchSelectRotationGoals(user, token, challengeId);
  }
  sleep(randomBetween(3, 5));

  // === STEP 3.5: Mixed mode - also interact with absolute challenge (30%) ===
  if (Math.random() < 0.3) {
    batchSelectAbsoluteGoals(user, token);
    sleep(randomBetween(1, 2));
  }

  // === STEP 4: Gameplay (simulated by sleep, events flow in background) ===
  sleep(randomBetween(5, 10));

  // === STEP 5: Check Rotation Status ===
  getRotationStatus(user, token, challengeId);
  sleep(randomBetween(1, 2));

  // === STEP 6: Check Progress ===
  checkRotationProgress(user, token, challengeId);
  sleep(randomBetween(2, 3));

  // === STEP 7: Claim Reward (30% of sessions) ===
  if (Math.random() < 0.3) {
    claimRotationGoal(user, token, challengeId);
    sleep(randomBetween(1, 2));

    // === STEP 7.5: Re-browse after claim (verify rotation display) ===
    browseChallengesWithRotationChecks(user, token);
  }

  // === STEP 8: GDPR Delete (10% of sessions) ===
  if (Math.random() < 0.1) {
    callGdprDelete(user, token);
    sleep(randomBetween(1, 2));

    // === STEP 8.5: Re-browse after delete (verify data cleared) ===
    browseChallengesAfterDelete(user, token);
  }

  // === Session Gap ===
  sleep(randomBetween(5, 10));
}

// ============================================================================
// API HELPER FUNCTIONS
// ============================================================================

function createHeaders(user, token) {
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Mock-User-Id': user.id,
  };
}

function callInitialize(user, token) {
  const resp = http.post(`${BASE_URL}/v1/challenges/initialize`, '{}', {
    headers: createHeaders(user, token),
    tags: { endpoint: 'initialize' },
  });

  check(resp, {
    'Initialize: status 200': (r) => r.status === 200,
    'Initialize: has assigned_goals': (r) => {
      const body = r.json();
      return body.assignedGoals && body.assignedGoals.length >= 0;
    },
  });
}

function browseChallengesWithRotationChecks(user, token) {
  const resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: createHeaders(user, token),
    tags: { endpoint: 'browse_challenges' },
  });

  check(resp, {
    'Browse: status 200': (r) => r.status === 200,
    'Browse: has challenges': (r) => {
      const body = r.json();
      return body.challenges && body.challenges.length > 0;
    },
    'Browse: rotation goals have expiresAt': (r) => {
      const body = r.json();
      const daily = body.challenges.find(c => c.challengeId === 'daily-challenges');
      if (!daily || !daily.goals) return false;
      return daily.goals.some(g => g.expiresAt && g.expiresAt.length > 0);
    },
    'Browse: rotation goals have expiresInSeconds': (r) => {
      const body = r.json();
      const daily = body.challenges.find(c => c.challengeId === 'daily-challenges');
      if (!daily || !daily.goals) return false;
      return daily.goals.some(g => g.expiresInSeconds && g.expiresInSeconds > 0);
    },
  });
}

function getRotationStatus(user, token, challengeId) {
  const resp = http.get(
    `${BASE_URL}/v1/challenges/${challengeId}/rotation`,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'rotation_status' },
    }
  );

  check(resp, {
    'Rotation: status 200': (r) => r.status === 200,
    'Rotation: has enabled field': (r) => {
      const body = r.json();
      return body.rotation && body.rotation.enabled === true;
    },
    'Rotation: has current_period': (r) => {
      const body = r.json();
      return body.rotation && body.rotation.currentPeriod && body.rotation.currentPeriod.expiresInSeconds > 0;
    },
  });
}

function randomSelectRotationGoals(user, token, challengeId) {
  const payload = JSON.stringify({
    count: 3,
    replace_existing: true,
    exclude_active: true,
  });

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${challengeId}/goals/random-select`,
    payload,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'random_select' },
      responseCallback: http.expectedStatuses(200, 400),
    }
  );

  check(resp, {
    'Random Select: status 200 or 400': (r) => r.status === 200 || r.status === 400,
    'Random Select: has selected_goals': (r) => {
      if (r.status !== 200) return true;
      const body = r.json();
      return body.selectedGoals && body.selectedGoals.length > 0;
    },
  });
}

function batchSelectAbsoluteGoals(user, token) {
  const payload = JSON.stringify({
    goal_ids: ['challenge-001-goal-01', 'challenge-001-goal-02', 'challenge-001-goal-03'],
    replace_existing: false,
  });

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${ABSOLUTE_CHALLENGE_ID}/goals/batch-select`,
    payload,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'batch_select' },
    }
  );

  check(resp, {
    'Absolute Batch Select: status 200': (r) => r.status === 200,
  });
}

function batchSelectRotationGoals(user, token, challengeId) {
  const goalPrefix = challengeId === 'daily-challenges' ? 'daily-goal' : 'weekly-goal';
  const goalIds = [
    `${goalPrefix}-01`,
    `${goalPrefix}-02`,
    `${goalPrefix}-03`,
  ];

  const payload = JSON.stringify({
    goal_ids: goalIds,
    replace_existing: false,
  });

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${challengeId}/goals/batch-select`,
    payload,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'batch_select' },
    }
  );

  check(resp, {
    'Batch Select: status 200': (r) => r.status === 200,
    'Batch Select: has selected_goals': (r) => {
      const body = r.json();
      return body.selectedGoals && body.selectedGoals.length > 0;
    },
  });
}

function checkRotationProgress(user, token, challengeId) {
  const resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: createHeaders(user, token),
    tags: { endpoint: 'check_progress' },
  });

  check(resp, {
    'Progress: status 200': (r) => r.status === 200,
    'Progress: has rotation challenge': (r) => {
      const body = r.json();
      return body.challenges && body.challenges.some(c => c.challengeId === challengeId);
    },
  });
}

function claimRotationGoal(user, token, challengeId) {
  const goalPrefix = challengeId === 'daily-challenges' ? 'daily-goal' : 'weekly-goal';
  const goalId = `${goalPrefix}-01`;

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${challengeId}/goals/${goalId}/claim`,
    null,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'claim' },
      responseCallback: http.expectedStatuses(200, 400),
    }
  );

  check(resp, {
    'Claim: status 200 or 400': (r) => r.status === 200 || r.status === 400,
  });
}

// ============================================================================
// M6 GDPR DELETE ENDPOINT
// ============================================================================

function callGdprDelete(user, token) {
  const resp = http.del(`${BASE_URL}/v1/users/me/data`, null, {
    headers: createHeaders(user, token),
    tags: { endpoint: 'gdpr_delete' },
    responseCallback: http.expectedStatuses(200, 429),
  });

  check(resp, {
    'GDPR Delete: status 200 or 429': (r) => r.status === 200 || r.status === 429,
  });
}

// ============================================================================
// POST-DELETE VERIFICATION
// ============================================================================
// Lightweight browse after GDPR delete: verifies config-level challenges still
// return but user's progress data is cleared. Does NOT check expiresAt since
// deleted users have no rotation goal rows yet.
// ============================================================================

function browseChallengesAfterDelete(user, token) {
  const resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: createHeaders(user, token),
    tags: { endpoint: 'browse_after_delete' },
  });

  check(resp, {
    'Post-Delete Browse: status 200': (r) => r.status === 200,
    'Post-Delete Browse: has challenges': (r) => {
      const body = r.json();
      return body.challenges && body.challenges.length > 0;
    },
    'Post-Delete Browse: no completed/claimed goals': (r) => {
      const body = r.json();
      if (!body.challenges) return false;
      for (const c of body.challenges) {
        if (!c.goals) continue;
        for (const g of c.goals) {
          if (g.status === 'completed' || g.status === 'claimed') return false;
        }
      }
      return true;
    },
  });
}

// ============================================================================
// BACKGROUND EVENT LOAD - gRPC Login + Stat Events (20/80 split)
// ============================================================================

export function eventLoad() {
  const user = users[Math.floor(Math.random() * users.length)];

  // Connect once per VU (not per iteration) - PERFORMANCE FIX
  if (!loginConnected) {
    loginClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    loginConnected = true;
  }
  if (!statConnected) {
    statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    statConnected = true;
  }

  // 20% login events, 80% stat events (matches scenario3/4 pattern)
  if (Math.random() < 0.2) {
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('accelbyte.iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);
    check(response, { 'Event: login OK': (r) => r && r.status === grpc.StatusOK });
  } else {
    const statCodes = ['enemy_kills', 'games_played', 'headshots', 'wins'];
    const statMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
      payload: {
        statCode: statCodes[Math.floor(Math.random() * statCodes.length)],
        latestValue: Math.floor(Math.random() * 1000),
        inc: Math.floor(Math.random() * 10) + 1,
      },
    };

    const response = statClient.invoke('accelbyte.social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);
    check(response, { 'Event: stat OK': (r) => r && r.status === grpc.StatusOK });
  }
}

// ============================================================================
// M6 CLEANUP METRICS MONITOR
// ============================================================================
// Periodically scrapes Prometheus metrics endpoint to track cleanup goroutine
// activity. Logs rows_deleted_total for observability during the test.
// ============================================================================

export function monitorCleanup() {
  const resp = http.get(METRICS_URL, {
    tags: { endpoint: 'metrics_scrape' },
  });

  check(resp, {
    'Metrics: status 200': (r) => r.status === 200,
    'Metrics: has cleanup metrics': (r) => {
      return r.body && r.body.includes('challenge_cleanup');
    },
  });

  if (resp.status === 200 && resp.body) {
    const rowsMatch = resp.body.match(/challenge_cleanup_rows_deleted_total\s+([\d.e+]+)/);
    const cyclesMatch = resp.body.match(/challenge_cleanup_cycles_total\s+([\d.e+]+)/);
    const errorsMatch = resp.body.match(/challenge_cleanup_errors_total\s+([\d.e+]+)/);

    const rowsDeleted = rowsMatch ? rowsMatch[1] : 'N/A';
    const cycles = cyclesMatch ? cyclesMatch[1] : 'N/A';
    const errors = errorsMatch ? errorsMatch[1] : 'N/A';

    console.log(`[cleanup-monitor] rows_deleted=${rowsDeleted} cycles=${cycles} errors=${errors}`);
  }
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}

function randomBetween(min, max) {
  return min + Math.random() * (max - min);
}

// ============================================================================
// SETUP AND TEARDOWN
// ============================================================================

export function setup() {
  console.log('\n=== M6 Cleanup Validation Load Test ===');
  console.log(`VUs: ${TARGET_VUS}, Iterations: ${ITERATIONS}, EPS: ${TARGET_EPS}`);
  console.log(`Metrics endpoint: ${METRICS_URL}`);
  console.log(`GDPR delete: 10% of user sessions`);

  // Verify metrics endpoint is reachable
  const metricsResp = http.get(METRICS_URL);
  if (metricsResp.status !== 200) {
    console.warn(`WARNING: Metrics endpoint ${METRICS_URL} returned status ${metricsResp.status}`);
  }

  // Capture initial cleanup counter value
  let initialRowsDeleted = 0;
  if (metricsResp.status === 200 && metricsResp.body) {
    const match = metricsResp.body.match(/challenge_cleanup_rows_deleted_total\s+([\d.e+]+)/);
    if (match) {
      initialRowsDeleted = parseFloat(match[1]);
    }
  }

  console.log(`Initial challenge_cleanup_rows_deleted_total: ${initialRowsDeleted}`);

  return { initialRowsDeleted: initialRowsDeleted };
}

export function teardown(data) {
  // Final metrics scrape
  const metricsResp = http.get(METRICS_URL);
  let finalRowsDeleted = 0;
  let finalCycles = 0;
  let finalErrors = 0;

  if (metricsResp.status === 200 && metricsResp.body) {
    const rowsMatch = metricsResp.body.match(/challenge_cleanup_rows_deleted_total\s+([\d.e+]+)/);
    const cyclesMatch = metricsResp.body.match(/challenge_cleanup_cycles_total\s+([\d.e+]+)/);
    const errorsMatch = metricsResp.body.match(/challenge_cleanup_errors_total\s+([\d.e+]+)/);

    finalRowsDeleted = rowsMatch ? parseFloat(rowsMatch[1]) : 0;
    finalCycles = cyclesMatch ? parseFloat(cyclesMatch[1]) : 0;
    finalErrors = errorsMatch ? parseFloat(errorsMatch[1]) : 0;
  }

  const rowsDeletedDuringTest = finalRowsDeleted - (data.initialRowsDeleted || 0);

  console.log('\n=== M6 Cleanup Validation Complete ===');
  console.log(`Rows deleted during test: ${rowsDeletedDuringTest}`);
  console.log(`Total cleanup cycles: ${finalCycles}`);
  console.log(`Total cleanup errors: ${finalErrors}`);

  console.log('\nSuccess criteria checklist:');
  console.log(`  [${rowsDeletedDuringTest > 0 ? 'PASS' : 'CHECK'}] Cleanup goroutine deleted rows (${rowsDeletedDuringTest})`);
  console.log(`  [${finalErrors === 0 ? 'PASS' : 'FAIL'}] Zero cleanup errors (${finalErrors})`);
  console.log('  - browse_challenges p95 < 500ms');
  console.log('  - rotation_status p95 < 100ms');
  console.log('  - gdpr_delete p95 < 500ms');
  console.log('  - metrics_scrape p95 < 200ms');
  console.log('  - gRPC event p95 < 500ms');
  console.log('  - Overall http_req_failed < 1%');
}
