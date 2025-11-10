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
const TARGET_RPS = parseInt(__ENV.TARGET_RPS || '100');

export let options = {
  scenarios: {
    api_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      duration: '10m',
      preAllocatedVUs: Math.min(TARGET_RPS, 1000),
      maxVUs: Math.min(TARGET_RPS * 2, 2000),
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<2000'],  // p95 < 2 seconds
    'http_req_failed': ['rate<0.01'],     // error rate < 1%
  },
};

export default function() {
  // Randomly select user and token
  const userIndex = Math.floor(Math.random() * users.length);
  const user = users[userIndex];
  const token = tokens[userIndex];

  // Test GET /v1/challenges (80% of requests)
  if (Math.random() < 0.8) {
    const resp = http.get(`${BASE_URL}/v1/challenges`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });

    check(resp, {
      'GET challenges: status 200': (r) => r.status === 200,
      'GET challenges: has data': (r) => {
        const body = JSON.parse(r.body);
        return body.challenges && body.challenges.length > 0;
      },
    });
  }
  // Test POST /claim (20% of requests)
  else {
    // First get challenges to find completed goal
    const getChallengesResp = http.get(`${BASE_URL}/v1/challenges`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });

    if (getChallengesResp.status === 200) {
      const data = JSON.parse(getChallengesResp.body);
      const completedGoals = findCompletedGoals(data.challenges);

      if (completedGoals.length > 0) {
        const goal = completedGoals[0];
        const claimResp = http.post(
          `${BASE_URL}/v1/challenges/${goal.challengeId}/goals/${goal.goalId}/claim`,
          null,
          { headers: { 'Authorization': `Bearer ${token}` } }
        );

        check(claimResp, {
          'POST claim: status 200 or 409': (r) => r.status === 200 || r.status === 409,
        });
      }
    }
  }

  // No sleep - constant-arrival-rate executor handles pacing
}

function findCompletedGoals(challenges) {
  const completed = [];
  if (!challenges) return completed;

  for (const challenge of challenges) {
    if (!challenge.goals) continue;

    for (const goal of challenge.goals) {
      if (goal.status === 'completed' && !goal.claimed_at) {
        completed.push({
          challengeId: challenge.id,
          goalId: goal.id,
        });
      }
    }
  }
  return completed;
}
