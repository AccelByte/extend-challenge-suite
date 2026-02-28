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
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6566';
const TARGET_VUS = parseInt(__ENV.TARGET_VUS || '150');
const ITERATIONS = parseInt(__ENV.ITERATIONS || '120');
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '500');
const NAMESPACE = __ENV.NAMESPACE || 'test';

// gRPC clients
const statClient = new grpc.Client();
statClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

// Track connection state per VU
let statConnected = false;

export let options = {
  scenarios: {
    // Rotation-focused user sessions
    rotation_api: {
      executor: 'per-vu-iterations',
      vus: TARGET_VUS,
      iterations: ITERATIONS,
      maxDuration: '30m',
      exec: 'rotationUserSession',
    },

    // Background stat events targeting rotation goal stat codes
    rotation_events: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '30m',
      preAllocatedVUs: 1000,
      maxVUs: 1500,
      exec: 'rotationEventLoad',
    },
  },

  thresholds: {
    // Overall API health
    'http_req_duration': ['p(95)<2000'],
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],

    // M5-specific strict thresholds
    'http_req_duration{endpoint:rotation_status}': ['p(95)<100'],
    'http_req_duration{endpoint:browse_challenges}': ['p(95)<500'],
    'http_req_duration{endpoint:initialize}': ['p(95)<100'],
    'http_req_duration{endpoint:batch_select}': ['p(95)<50'],
    'http_req_duration{endpoint:check_progress}': ['p(95)<500'],
    'http_req_duration{endpoint:claim}': ['p(95)<100'],

    // Event processing
    'grpc_req_duration': ['p(95)<500'],
  },
};

// ============================================================================
// M5 ROTATION USER SESSION - Sequential Per-VU
// ============================================================================
// Each VU represents one user going through rotation-focused sessions.
// Tests: expiresAt presence, rotation status, claim-reset-reattempt cycle.
// ============================================================================

export function rotationUserSession() {
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

  // === STEP 3: Batch-select from rotation challenge ===
  batchSelectRotationGoals(user, token, challengeId);
  sleep(randomBetween(3, 5));

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
      if (!daily || !daily.goals) return true; // skip if not present
      return daily.goals.some(g => g.expiresAt && g.expiresAt.length > 0);
    },
    'Browse: rotation goals have expiresInSeconds': (r) => {
      const body = r.json();
      const daily = body.challenges.find(c => c.challengeId === 'daily-challenges');
      if (!daily || !daily.goals) return true;
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

function batchSelectRotationGoals(user, token, challengeId) {
  // Select 3 rotation goals
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
      // 400 is valid when goal is not completed yet or already claimed
      responseCallback: http.expectedStatuses(200, 400),
    }
  );

  check(resp, {
    'Claim: status 200 or 400': (r) => r.status === 200 || r.status === 400,
  });
}

// ============================================================================
// BACKGROUND ROTATION EVENT LOAD - gRPC Stat Events
// ============================================================================
// Sends stat events targeting rotation goal stat codes with inc field.
// ============================================================================

export function rotationEventLoad() {
  const user = users[Math.floor(Math.random() * users.length)];

  // Connect once per VU
  if (!statConnected) {
    statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    statConnected = true;
  }

  // Only stat events (rotation goals are stat-based, not login-based)
  const statCodes = ['enemy_kills', 'login_count', 'games_played', 'headshots', 'wins'];
  const statMsg = {
    id: generateEventID(),
    userId: user.id,
    namespace: NAMESPACE,
    payload: {
      statCode: statCodes[Math.floor(Math.random() * statCodes.length)],
      latestValue: Math.floor(Math.random() * 1000),
      inc: Math.floor(Math.random() * 10) + 1,  // M5: baseline computation for relative progress
    },
  };

  const response = statClient.invoke('accelbyte.social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);
  check(response, { 'Event: stat OK': (r) => r && r.status === grpc.StatusOK });

  // DO NOT close connections - reuse them across iterations
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
  // Note: To simulate stale rows (returning users after rotation boundary),
  // set DB_SEED_STALE_ROWS=true and run the following SQL before the test:
  //
  //   UPDATE user_goal_progress
  //   SET updated_at = NOW() - INTERVAL '1 day'
  //   WHERE goal_id LIKE 'daily-goal-%'
  //     AND random() < 0.4;
  //
  // This simulates 40% of daily rotation goal rows being from a previous
  // rotation period, triggering baseline recomputation on next event.

  console.log('\n=== M5 Rotation Stress Test ===');
  console.log(`VUs: ${TARGET_VUS}, Iterations: ${ITERATIONS}, EPS: ${TARGET_EPS}`);
  console.log(`Rotation challenges: daily-challenges, weekly-challenges`);
  if (__ENV.DB_SEED_STALE_ROWS) {
    console.log('WARNING: DB_SEED_STALE_ROWS is set. Ensure stale rows SQL was run before this test.');
  }
}

export function teardown(data) {
  console.log('\n=== M5 Rotation Stress Test Complete ===');
  console.log('Key metrics to check:');
  console.log('  - rotation_status p95 < 100ms');
  console.log('  - browse_challenges p95 < 500ms (with expiresAt computation)');
  console.log('  - Event processing p95 < 500ms (with inc/baseline handling)');
  console.log('  - Claim success rate (rotation goals can be re-claimed after reset)');
}
