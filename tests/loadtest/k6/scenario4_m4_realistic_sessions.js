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
const CHALLENGE_ID = __ENV.CHALLENGE_ID || 'daily-challenges';

// gRPC clients
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

loginClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

// Track connection state per VU (PERFORMANCE FIX: connect once, reuse)
let loginConnected = false;
let statConnected = false;

export let options = {
  scenarios: {
    // Sequential user sessions - realistic user journey
    user_sessions: {
      executor: 'per-vu-iterations',
      vus: TARGET_VUS,              // Concurrent users
      iterations: ITERATIONS,        // Sessions per user
      maxDuration: '30m',
      exec: 'userSession',
    },

    // Background event load - continuous stat updates
    event_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '30m',
      preAllocatedVUs: 1000,
      maxVUs: 1500,
      exec: 'eventLoad',
    },
  },

  thresholds: {
    // Overall API health
    'http_req_duration': ['p(95)<2000'],
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],

    // M4-specific strict thresholds
    'http_req_duration{endpoint:batch_select}': ['p(95)<50'],
    'http_req_duration{endpoint:random_select}': ['p(95)<50'],

    // Other endpoint-specific thresholds
    'http_req_duration{endpoint:initialize}': ['p(95)<100'],
    'http_req_duration{endpoint:browse_challenges}': ['p(95)<500'],
    'http_req_duration{endpoint:check_progress}': ['p(95)<500'],
    'http_req_duration{endpoint:claim}': ['p(95)<100'],

    // Event processing
    'grpc_req_duration': ['p(95)<500'],
  },
};

// ============================================================================
// REALISTIC USER SESSION - Sequential Per-VU
// ============================================================================
// Each VU represents one user going through multiple complete sessions
// Each iteration = one realistic user journey from start to finish
// ============================================================================

export function userSession() {
  const token = tokens[__VU % tokens.length];
  const user = users[__VU % users.length];

  // === STEP 1: Session Start - Initialize ===
  callInitialize(user, token);
  sleep(randomBetween(1, 2));

  // === STEP 2: Browse Challenges ===
  getBrowseChallenges(user, token);
  sleep(randomBetween(2, 4));

  // === STEP 3: Select Goals (M4 - NEW) ===
  // 60% prefer random "surprise me", 40% manual selection
  if (Math.random() < 0.6) {
    randomSelectGoals(user, token);
  } else {
    batchSelectGoals(user, token);
  }
  sleep(randomBetween(3, 5));

  // === STEP 4: Gameplay (simulated by sleep) ===
  // Stat update events happen in background via event_load scenario
  sleep(randomBetween(5, 10));

  // === STEP 5: Check Progress ===
  getSpecificChallenge(user, token);
  sleep(randomBetween(2, 3));

  // === STEP 6: Claim Reward (if goal completed) ===
  // Not every session completes a goal (30% completion rate)
  if (Math.random() < 0.3) {
    claimGoal(user, token);
  }

  // === Session Gap ===
  // Time before user starts a new session
  sleep(randomBetween(5, 10));
}

// ============================================================================
// API HELPER FUNCTIONS - HTTP Endpoints
// ============================================================================

function createHeaders(user, token) {
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Mock-User-Id': user.id,  // Mock auth header for load testing
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

function getBrowseChallenges(user, token) {
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
  });
}

function getSpecificChallenge(user, token) {
  // API only supports getting all challenges, so we fetch all and filter
  const resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: createHeaders(user, token),
    tags: { endpoint: 'check_progress' },
  });

  check(resp, {
    'Progress: status 200': (r) => r.status === 200,
    'Progress: has challenge data': (r) => {
      const body = r.json();
      return body.challenges && body.challenges.some(c => c.challengeId === CHALLENGE_ID);
    },
  });
}

// ============================================================================
// M4 ENDPOINTS - Batch and Random Selection
// ============================================================================

function batchSelectGoals(user, token) {
  // Simulate user selecting 3 goals manually
  const goalIds = [
    'daily-login',
    'daily-10-kills',
    'daily-3-matches',
  ];

  const payload = JSON.stringify({
    goal_ids: goalIds,
    replace_existing: false,
  });

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${CHALLENGE_ID}/goals/batch-select`,
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
    'Batch Select: p95 < 50ms': (r) => r.timings.duration < 50,
  });
}

function randomSelectGoals(user, token) {
  // Simulate user clicking "Surprise Me" for 5 random goals
  const payload = JSON.stringify({
    count: 5,
    replace_existing: false,
    exclude_active: true,
  });

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${CHALLENGE_ID}/goals/random-select`,
    payload,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'random_select' },
    }
  );

  check(resp, {
    'Random Select: status 200': (r) => r.status === 200,
    'Random Select: has selected_goals': (r) => {
      const body = r.json();
      return body.selectedGoals && body.selectedGoals.length > 0;
    },
    'Random Select: p95 < 50ms': (r) => r.timings.duration < 50,
  });
}

function claimGoal(user, token) {
  // Claim first goal (in real scenario, would track which goals are completed)
  const goalId = 'daily-login';

  const resp = http.post(
    `${BASE_URL}/v1/challenges/${CHALLENGE_ID}/goals/${goalId}/claim`,
    null,
    {
      headers: createHeaders(user, token),
      tags: { endpoint: 'claim' },
      // IMPORTANT: Mark both 200 and 400 as expected responses
      // 400 is valid when goal is not completed yet or already claimed
      // This prevents k6 from counting 400s as failures in http_req_failed metric
      responseCallback: http.expectedStatuses(200, 400),
    }
  );

  check(resp, {
    'Claim: status 200 or 400': (r) => r.status === 200 || r.status === 400,
    // 400 is acceptable (goal not completed yet or already claimed)
  });
}

// ============================================================================
// BACKGROUND EVENT LOAD - gRPC Events
// ============================================================================
// Simulates continuous gameplay events (login, stat updates)
// Runs in parallel with user sessions
// ============================================================================

export function eventLoad() {
  const user = users[Math.floor(Math.random() * users.length)];

  // Connect once per VU (not per iteration) - PERFORMANCE FIX
  // This eliminates ~8-10ms connection overhead per event
  if (!loginConnected) {
    loginClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    loginConnected = true;
  }
  if (!statConnected) {
    statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    statConnected = true;
  }

  // 20% login, 80% stat updates
  if (Math.random() < 0.2) {
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('accelbyte.iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);
    check(response, { 'Event: login OK': (r) => r && r.status === grpc.StatusOK });
  } else {
    const statCodes = ['enemy_kills', 'login_count', 'games_played', 'headshots', 'wins'];
    const statMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
      payload: {
        statCode: statCodes[Math.floor(Math.random() * statCodes.length)],
        latestValue: Math.floor(Math.random() * 1000),
      },
    };

    const response = statClient.invoke('accelbyte.social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);
    check(response, { 'Event: stat OK': (r) => r && r.status === grpc.StatusOK });
  }

  // DO NOT close connections - reuse them across iterations
  // k6 will automatically clean up when VU terminates
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
