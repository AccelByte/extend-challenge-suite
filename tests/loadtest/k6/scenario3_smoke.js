import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

// Load test data
const tokens = new SharedArray('tokens', function() {
  return JSON.parse(open('../fixtures/tokens.json'));
});

const users = new SharedArray('users', function() {
  return JSON.parse(open('../fixtures/users.json'));
});

const challengesData = JSON.parse(open('../test/fixtures/challenges.json'));
const challenges = challengesData.challenges;

// Configuration
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000/challenge';
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6566';
const NAMESPACE = __ENV.NAMESPACE || 'test';

// SMOKE TEST: Reduced load for quick validation (100 RPS API, 200 EPS events)
// Duration: 5 minutes (vs 32 minutes for full test)
const TARGET_RPS = 100;
const TARGET_EPS = 200;

// gRPC clients
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

// Proto files (adjust paths as needed)
loginClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

let loginConnected = false;
let statConnected = false;

function createHeaders(user, token) {
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Mock-User-Id': user.id,  // Mock auth header for load testing
  };
}

export let options = {
  scenarios: {
    // Phase 1: Init burst (0-30s, 100 RPS) - Quick initialization
    initialization_phase: {
      exec: 'initializationPhase',
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      duration: '30s',
      startTime: '0s',
      preAllocatedVUs: 100,
      maxVUs: 200,
    },
    // Phase 2: API gameplay (30s-5m, 100 RPS) - Sustained load
    api_gameplay: {
      exec: 'apiGameplayPhase',
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      duration: '4m30s',
      startTime: '30s',
      preAllocatedVUs: 100,
      maxVUs: 200,
    },
    // Phase 2: Event processing (30s-5m, 200 EPS)
    event_gameplay: {
      exec: 'eventGameplayPhase',
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '4m30s',
      startTime: '30s',
      preAllocatedVUs: 200,
      maxVUs: 300,
    },
  },
  thresholds: {
    // Same thresholds as full test (validation should pass at lower load)
    'http_req_duration{endpoint:initialize,phase:init}': ['p(95)<100'],
    'http_req_duration{endpoint:initialize,phase:gameplay}': ['p(95)<50'],
    'http_req_duration{endpoint:challenges}': ['p(95)<200'],
    'http_req_duration{endpoint:set_active}': ['p(95)<100'],
    'grpc_req_duration': ['p(95)<500'],
    'checks': ['rate>0.99'],  // 99% success rate
  },
};

// ============================================================================
// Phase 1: Initialization Phase (All users initialize)
// ============================================================================

export function initializationPhase() {
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
        phase: 'init',
      },
    }
  );

  check(resp, {
    'init phase: status 200': (r) => r.status === 200,
    'init phase: has assignedGoals': (r) => {
      if (r.status !== 200) {
        console.log(`Init failed: ${r.status} - ${r.body}`);
        return false;
      }
      const body = JSON.parse(r.body);
      return body.assignedGoals && body.assignedGoals.length > 0;
    },
  });
}

// ============================================================================
// Phase 2: API Gameplay (Mixed realistic behavior)
// ============================================================================

export function apiGameplayPhase() {
  const userIndex = Math.floor(Math.random() * users.length);
  const user = users[userIndex];
  const token = tokens[userIndex];
  const roll = Math.random();

  // 10% - Call initialize again (testing fast path)
  if (roll < 0.10) {
    const resp = http.post(
      `${BASE_URL}/v1/challenges/initialize`,
      '{}',
      {
        headers: createHeaders(user, token),
        tags: {
          endpoint: 'initialize',
          phase: 'gameplay',
        },
      }
    );

    check(resp, {
      'gameplay init: status 200': (r) => r.status === 200,
      'gameplay init: fast path': (r) => {
        if (r.status !== 200) return false;
        const body = JSON.parse(r.body);
        return body.newAssignments === 0;  // Should be 0 (already initialized)
      },
    });
  }
  // 15% - Activate/deactivate goals
  else if (roll < 0.25) {
    const challenge = challenges[Math.floor(Math.random() * challenges.length)];
    const goal = challenge.goals[Math.floor(Math.random() * challenge.goals.length)];
    const isActive = Math.random() < 0.5;

    const resp = http.put(
      `${BASE_URL}/v1/challenges/${challenge.challengeId}/goals/${goal.goalId}/active`,
      JSON.stringify({ is_active: isActive }),
      {
        headers: createHeaders(user, token),
        tags: {
          endpoint: 'set_active',
          action: isActive ? 'activate' : 'deactivate',
        },
      }
    );

    check(resp, {
      'set_active: status 200': (r) => {
        if (r.status !== 200) {
          console.log(`Set active failed: ${r.status} - ${r.body}`);
          return false;
        }
        return true;
      },
    });
  }
  // 5% - Claim reward
  else if (roll < 0.30) {
    // First get challenges to find completed goal
    const getChallengesResp = http.get(`${BASE_URL}/v1/challenges?active_only=true`, {
      headers: createHeaders(user, token),
    });

    if (getChallengesResp.status === 200) {
      const data = JSON.parse(getChallengesResp.body);
      const completedGoals = findCompletedGoals(data.challenges);

      if (completedGoals.length > 0) {
        const goal = completedGoals[0];
        const claimResp = http.post(
          `${BASE_URL}/v1/challenges/${goal.challengeId}/goals/${goal.goalId}/claim`,
          null,
          {
            headers: createHeaders(user, token),
            tags: { endpoint: 'claim' },
          }
        );

        check(claimResp, {
          'claim: status 200 or 409': (r) => r.status === 200 || r.status === 409,
        });
      }
    }
  }
  // 70% - Query challenges (with/without active_only)
  else {
    const useActiveOnly = Math.random() < 0.5;
    const url = useActiveOnly
      ? `${BASE_URL}/v1/challenges?active_only=true`
      : `${BASE_URL}/v1/challenges`;

    const resp = http.get(url, {
      headers: createHeaders(user, token),
      tags: {
        endpoint: 'challenges',
        active_only: useActiveOnly.toString(),
      },
    });

    check(resp, {
      'challenges: status 200': (r) => {
        if (r.status !== 200) {
          console.log(`Challenges failed: ${r.status} - ${r.body}`);
          return false;
        }
        return true;
      },
      'challenges: has data': (r) => {
        if (r.status !== 200) return false;
        const body = JSON.parse(r.body);
        return body.challenges && body.challenges.length > 0;
      },
    });
  }
}

// ============================================================================
// Phase 2: Event Gameplay (Same as M2, M3 filters automatically)
// ============================================================================

export function eventGameplayPhase() {
  const user = users[Math.floor(Math.random() * users.length)];

  // Connect once per VU
  if (!loginConnected) {
    loginClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    loginConnected = true;
  }
  if (!statConnected) {
    statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
    statConnected = true;
  }

  // 20% login events, 80% stat update events
  if (Math.random() < 0.2) {
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('accelbyte.iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);

    check(response, {
      'login event processed': (r) => {
        if (!r || r.status !== grpc.StatusOK) {
          console.log(`Login event failed: ${r ? r.status : 'null response'}`);
          return false;
        }
        return true;
      },
    });
  } else {
    const statCodes = ['enemy_kills', 'login_count', 'games_played', 'headshots', 'wins'];
    const statCode = statCodes[Math.floor(Math.random() * statCodes.length)];

    const statMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
      payload: {
        statCode: statCode,
        latestValue: Math.floor(Math.random() * 1000),
      },
    };

    const response = statClient.invoke('accelbyte.social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);

    check(response, {
      'stat event processed': (r) => {
        if (!r || r.status !== grpc.StatusOK) {
          console.log(`Stat event failed: ${r ? r.status : 'null response'}`);
          return false;
        }
        return true;
      },
    });
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

function findCompletedGoals(challenges) {
  const completed = [];
  if (!challenges) return completed;

  for (const challenge of challenges) {
    if (!challenge.goals) continue;

    for (const goal of challenge.goals) {
      if (goal.status === 'completed' && !goal.claimed_at) {
        completed.push({
          challengeId: challenge.challengeId,
          goalId: goal.goalId,
        });
      }
    }
  }
  return completed;
}

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}

// ============================================================================
// Teardown (Verification)
// ============================================================================

export function teardown(data) {
  console.log('\n=== M3 Smoke Test Complete (5 minutes) ===');
  console.log('Duration: 5 minutes (vs 32 minutes for full test)');
  console.log('Load: 100 RPS API + 200 EPS events (vs 300 RPS + 500 EPS)');
  console.log('Purpose: Quick validation before running full load test');
  console.log('');
  console.log('If this test passes, proceed with full load test:');
  console.log('  cd tests/loadtest && ./scripts/run_loadtest.sh');
}
