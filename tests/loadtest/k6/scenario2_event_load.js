import grpc from 'k6/net/grpc';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

// Load test data
const users = new SharedArray('users', function() {
  return JSON.parse(open('../fixtures/users.json'));
});

// Configuration
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6566';
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '1000');
const NAMESPACE = __ENV.NAMESPACE || 'test';

// gRPC clients (created per VU, connections reused across iterations)
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

// Load proto files
// Note: Adjust paths based on your proto file location
loginClient.load(['../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../../extend-challenge-event-handler/pkg/proto/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

// Track connection state per VU
let loginConnected = false;
let statConnected = false;

export let options = {
  scenarios: {
    event_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '10m',
      preAllocatedVUs: 1000,  // Simulate Extend platform's 500 concurrent limit
      maxVUs: 1500,
    },
  },
  thresholds: {
    'grpc_req_duration': ['p(95)<500'],  // p95 < 500ms
    'checks': ['rate>0.99'],             // success rate > 99%
  },
};

export default function() {
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

  // 20% login events, 80% stat update events
  if (Math.random() < 0.2) {
    // Send login event
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('accelbyte.iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);

    check(response, {
      'login event processed': (r) => r && r.status === grpc.StatusOK,
    });
  } else {
    // Send stat update event
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
      'stat event processed': (r) => r && r.status === grpc.StatusOK,
    });
  }

  // DO NOT close connections - reuse them across iterations
  // k6 will automatically clean up when VU terminates
}

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}
