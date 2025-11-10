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

// Configuration
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000/challenge';
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6566';
const TARGET_RPS = parseInt(__ENV.TARGET_RPS || '300');
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '500');
const NAMESPACE = __ENV.NAMESPACE || 'test';

// gRPC clients
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

loginClient.load(['../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

// Track connection state per VU (PERFORMANCE FIX: connect once, reuse)
let loginConnected = false;
let statConnected = false;

export let options = {
  scenarios: {
    // API load scenario
    api_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      duration: '30m',
      preAllocatedVUs: Math.min(TARGET_RPS, 500),
      maxVUs: Math.min(TARGET_RPS * 2, 1000),
      exec: 'apiLoad',
    },
    // Event load scenario
    event_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '30m',
      preAllocatedVUs: 1000,  // Max concurrent events
      maxVUs: 1500,
      exec: 'eventLoad',
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<2000'],
    'http_req_failed': ['rate<0.01'],
    'grpc_req_duration': ['p(95)<500'],
    'checks': ['rate>0.99'],
  },
};

// API load function
export function apiLoad() {
  const userIndex = Math.floor(Math.random() * users.length);
  const token = tokens[userIndex];

  const resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  check(resp, {
    'API: status 200': (r) => r.status === 200,
  });
}

// Event load function
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

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}
