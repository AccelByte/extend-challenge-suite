# Technical Specification: Milestone 2 - Performance Profiling & Load Testing

**Document Version:** 1.0
**Date:** 2025-10-23
**Status:** Final
**Related Documents:**
- [MILESTONES.md](./MILESTONES.md) - M2 overview and success criteria
- [BRAINSTORM_M2.md](./BRAINSTORM_M2.md) - All design decisions (23 decisions)
- [TECH_SPEC_M1.md](./TECH_SPEC_M1.md) - M1 implementation reference

---

## Table of Contents

1. [Overview](#overview)
2. [Objectives](#objectives)
3. [Test Environment](#test-environment)
4. [Load Testing Tool: k6](#load-testing-tool-k6)
5. [Test Scenarios](#test-scenarios)
6. [Implementation Guide](#implementation-guide)
7. [Execution Procedures](#execution-procedures)
8. [Metrics Collection](#metrics-collection)
9. [Analysis and Reporting](#analysis-and-reporting)
10. [Deliverables](#deliverables)

---

## Overview

Milestone 2 (M2) focuses on **performance profiling and load testing** of the Challenge Service to determine actual system limits under resource constraints. This is a discovery phase—we aim to document reality, not force arbitrary performance targets.

### Key Philosophy

- **Find actual limits**, not hit predefined targets
- **Document bottlenecks**, not necessarily fix them all
- **Provide scaling recommendations** based on findings
- **Quality over speed**—long test duration is acceptable

### Critical Discovery: Event Concurrency

The AccelByte Extend platform handles events using **concurrent gRPC calls**:
- Opens 1 persistent gRPC connection
- Calls `OnMessage()` up to **500 times concurrently**
- Each call processes 1 event
- Parallel processing, not sequential batching

This means:
- 2,000 events/sec = 2,000 gRPC calls/sec with up to 500 concurrent
- Concurrency handling (goroutines, mutexes, buffer management) is critical
- k6 must simulate 500 concurrent virtual users (VUs)

---

## Objectives

### Primary Goals

1. **Find maximum sustainable API request rate (RPS)**
2. **Find maximum sustainable event processing rate (EPS)**
3. **Find maximum combined load** (API + Events simultaneously)
4. **Identify bottlenecks** (CPU, memory, database, concurrency)
5. **Provide scaling recommendations** for production deployment

### Success Criteria

M2 is complete when:
- ✅ All 5 test scenarios executed at multiple load levels
- ✅ Maximum capacity documented for each scenario
- ✅ Bottlenecks identified and explained
- ✅ 3 deliverable documents written
- ✅ Scaling recommendations provided

**NOT required:**
- ❌ Hitting arbitrary targets (e.g., "must achieve 1,000 RPS")
- ❌ Fixing all bottlenecks (just document them)
- ❌ Extensive optimization (2-3 passes max if time permits)

---

## Test Environment

### Deployment Architecture

**Local docker-compose deployment** with enforced resource limits:

```yaml
# docker-compose.yml resource configuration
services:
  challenge-service:
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M

  challenge-event-handler:
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M

  postgres:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          cpus: '1.0'
          memory: 2G
```

### Configuration

**Challenge Configuration:**
- 10 challenges
- 50 goals per challenge
- Total: 500 goals in system

**Database:**
- PostgreSQL 15
- Empty on test start (no pre-seeding)
- Connection pool: 50 connections
- Lazy row initialization

**Event Handler:**
- Buffer flush interval: 1 second
- Buffer size limit: 100,000 entries
- Per-user mutex for concurrency safety

**Mock AGS Platform Service:**
- Feature flag: `MOCK_AGS=true`
- Simulated latency: 50-200ms (random)
- No external API calls

### Load Testing Variables

**Fixed:**
- 10 challenges, 50 goals each
- Empty database start
- Buffer flush: 1 second
- DB pool: 50 connections

**Variable (tested at discrete levels):**

**API Request Rate (RPS):**
- Level 1: 50 RPS
- Level 2: 100 RPS
- Level 3: 200 RPS
- Level 4: 500 RPS
- Level 5: 1,000 RPS
- Level 6: 2,000 RPS
- Level 7: 5,000 RPS (or until failure)

**Event Rate (EPS):**
- Level 1: 100 EPS
- Level 2: 500 EPS
- Level 3: 1,000 EPS
- Level 4: 2,000 EPS
- Level 5: 5,000 EPS
- Level 6: 10,000 EPS (or until failure)

**Concurrency:**
- Max concurrent event calls: 500 (Extend platform limit)

### System at Limit Definition

Stop testing when **ANY** of the following occurs:
- ✅ Error rate > 1%
- ✅ API p95 latency > 2 seconds (10x baseline)
- ✅ Event processing p95 > 500ms (10x baseline)

**Note:** Resource exhaustion (CPU 95%, Memory 90%) alone does not define limit—only if it causes errors or latency spikes.

---

## Load Testing Tool: k6

### Why k6?

**k6** (https://k6.io) is our unified load testing tool:
- ✅ Supports both HTTP (REST API) and gRPC (events)
- ✅ Built-in metrics (p50, p95, p99, RPS, error rate)
- ✅ Web dashboard for real-time visualization
- ✅ Can run multiple scenarios in parallel
- ✅ Automatic threshold checking

### Installation

```bash
# macOS
brew install k6

# Linux (Debian/Ubuntu)
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6

# Docker
docker pull grafana/k6:latest
```

### k6 Web Dashboard

Real-time metrics visualization without Prometheus/Grafana:

```bash
k6 run --web-dashboard --out json=results.json scenario1_api_load.js

# Dashboard accessible at: http://localhost:5665
# Shows real-time graphs, latency percentiles, error rates
```

**Dashboard Features:**
- Request rate over time
- Response time (p50, p95, p99)
- Error rate percentage
- Active virtual users
- Data sent/received

---

## Test Scenarios

### Scenario 1: API Load Testing (Isolated)

**Duration:** 30 minutes
**Objective:** Find maximum sustainable API request rate without event load

**Test Flow:**
1. Start services with docker-compose
2. Run k6 API load at specified RPS
3. Monitor API response times and error rates
4. Stop at failure threshold

**k6 Script: `test/k6/scenario1_api_load.js`**

```javascript
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
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TARGET_RPS = parseInt(__ENV.TARGET_RPS || '100');

export let options = {
  scenarios: {
    api_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      duration: '30m',
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
```

**Running the test:**

```bash
# Level 1: 50 RPS
TARGET_RPS=50 k6 run --web-dashboard --out json=results_scenario1_level1.json test/k6/scenario1_api_load.js

# Level 2: 100 RPS
TARGET_RPS=100 k6 run --web-dashboard --out json=results_scenario1_level2.json test/k6/scenario1_api_load.js

# Continue increasing until failure...
```

**Metrics to collect:**
- HTTP request duration (p50, p95, p99)
- Request rate achieved (may be lower than target if system saturated)
- Error rate (%)
- Successful requests vs failed
- CPU and memory usage (via `docker stats`)

---

### Scenario 2: Event Processing Load (Isolated)

**Duration:** 30 minutes
**Objective:** Find maximum sustainable event processing rate without API load

**Event Mix:**
- 20% login events (`userLoggedIn`)
- 80% stat update events (`statItemUpdated`)

**Concurrency:**
- Up to 500 concurrent OnMessage calls (Extend platform limit)

**k6 Script: `test/k6/scenario2_event_load.js`**

```javascript
import grpc from 'k6/net/grpc';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

// Load test data
const users = new SharedArray('users', function() {
  return JSON.parse(open('../fixtures/users.json'));
});

// Configuration
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6565';
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '1000');
const NAMESPACE = __ENV.NAMESPACE || 'test';

// gRPC clients (created per VU)
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

loginClient.load(['../extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

export let options = {
  scenarios: {
    event_load: {
      executor: 'constant-arrival-rate',
      rate: TARGET_EPS,
      duration: '30m',
      preAllocatedVUs: 500,  // Simulate Extend platform's 500 concurrent limit
      maxVUs: 500,
    },
  },
  thresholds: {
    'grpc_req_duration': ['p(95)<500'],  // p95 < 500ms
    'checks': ['rate>0.99'],             // success rate > 99%
  },
};

export default function() {
  const user = users[Math.floor(Math.random() * users.length)];

  // Connect to event handler
  loginClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
  statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });

  // 20% login events, 80% stat update events
  if (Math.random() < 0.2) {
    // Send login event
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);

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

    const response = statClient.invoke('social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);

    check(response, {
      'stat event processed': (r) => r && r.status === grpc.StatusOK,
    });
  }

  loginClient.close();
  statClient.close();
}

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}
```

**Running the test:**

```bash
# Level 1: 100 EPS
TARGET_EPS=100 k6 run --web-dashboard --out json=results_scenario2_level1.json test/k6/scenario2_event_load.js

# Level 2: 500 EPS
TARGET_EPS=500 k6 run --web-dashboard --out json=results_scenario2_level2.json test/k6/scenario2_event_load.js

# Level 3: 1,000 EPS
TARGET_EPS=1000 k6 run --web-dashboard --out json=results_scenario2_level3.json test/k6/scenario2_event_load.js

# Continue increasing until failure...
```

**Metrics to collect:**
- gRPC request duration (p50, p95, p99)
- Event processing rate achieved
- Error rate (%)
- Active goroutines (via pprof)
- Buffer size (monitor event handler logs)
- CPU and memory usage

---

### Scenario 3: Combined Load Testing

**Duration:** 30 minutes
**Objective:** Test API + Event load simultaneously (most critical test)

**This scenario also includes CPU and memory profiling**

**Configuration:**
- API load at specified RPS
- Event load at specified EPS (with 500 concurrent max)
- Both running in parallel

**k6 Script: `test/k6/scenario3_combined.js`**

```javascript
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
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const EVENT_HANDLER_ADDR = __ENV.EVENT_HANDLER_ADDR || 'localhost:6565';
const TARGET_RPS = parseInt(__ENV.TARGET_RPS || '200');
const TARGET_EPS = parseInt(__ENV.TARGET_EPS || '1000');
const NAMESPACE = __ENV.NAMESPACE || 'test';

// gRPC clients
const loginClient = new grpc.Client();
const statClient = new grpc.Client();

loginClient.load(['../extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/iam/account/v1'], 'account.proto');
statClient.load(['../extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/social/statistic/v1'], 'statistic.proto');

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
      preAllocatedVUs: 500,  // Max concurrent events
      maxVUs: 500,
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

  loginClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });
  statClient.connect(EVENT_HANDLER_ADDR, { plaintext: true });

  // 20% login, 80% stat updates
  if (Math.random() < 0.2) {
    const loginMsg = {
      id: generateEventID(),
      userId: user.id,
      namespace: NAMESPACE,
    };

    const response = loginClient.invoke('iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage', loginMsg);
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

    const response = statClient.invoke('social.statistic.v1.StatisticStatItemUpdatedService/OnMessage', statMsg);
    check(response, { 'Event: stat OK': (r) => r && r.status === grpc.StatusOK });
  }

  loginClient.close();
  statClient.close();
}

function generateEventID() {
  return `k6-event-${Date.now()}-${Math.random().toString(36).substring(7)}`;
}
```

**Running the test:**

```bash
# Example: 200 RPS + 1,000 EPS
TARGET_RPS=200 TARGET_EPS=1000 k6 run --web-dashboard --out json=results_scenario3_level1.json test/k6/scenario3_combined.js
```

**While test is running, collect profiling data:**

```bash
# Terminal 2: CPU profiling (30 seconds)
go tool pprof -http=:8081 http://localhost:8080/debug/pprof/profile?seconds=30

# Terminal 3: Memory heap profiling
go tool pprof -http=:8082 http://localhost:8080/debug/pprof/heap

# Terminal 4: Goroutine profiling
go tool pprof -http=:8083 http://localhost:8080/debug/pprof/goroutine

# Terminal 5: Monitor docker stats
watch -n 2 'docker stats --no-stream'
```

**Metrics to collect:**
- All metrics from Scenario 1 + Scenario 2
- Resource contention indicators
- Database connection pool utilization
- CPU hotspots (from pprof)
- Memory allocation patterns (from pprof)
- Goroutine leaks (count over time)

---

### Scenario 4: Database Performance Deep Dive

**Duration:** 30 minutes
**Objective:** Same as Scenario 3, but with active database monitoring

**Test:** Run Scenario 3 at a specific load level while actively monitoring PostgreSQL.

**Database Monitoring Script: `test/scripts/monitor_db.sh`**

```bash
#!/bin/bash

# Monitor PostgreSQL performance during load test
# Usage: ./monitor_db.sh <output_file>

OUTPUT_FILE=${1:-"db_performance.log"}
INTERVAL=5  # seconds

echo "Monitoring PostgreSQL performance..."
echo "Output: $OUTPUT_FILE"
echo "Interval: ${INTERVAL}s"
echo ""

# Header
echo "timestamp,active_connections,idle_connections,total_queries,slow_queries,avg_query_time_ms" > "$OUTPUT_FILE"

while true; do
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  # Query PostgreSQL stats
  STATS=$(psql -U postgres -d challenge_db -t -c "
    SELECT
      COUNT(*) FILTER (WHERE state = 'active') as active_conn,
      COUNT(*) FILTER (WHERE state = 'idle') as idle_conn,
      (SELECT SUM(calls) FROM pg_stat_statements WHERE query LIKE '%user_goal_progress%') as total_queries,
      (SELECT COUNT(*) FROM pg_stat_statements WHERE mean_exec_time > 100 AND query LIKE '%user_goal_progress%') as slow_queries,
      (SELECT AVG(mean_exec_time) FROM pg_stat_statements WHERE query LIKE '%user_goal_progress%') as avg_time
    FROM pg_stat_activity;
  " | tr -d ' ' | tr '|' ',')

  echo "${TIMESTAMP},${STATS}" >> "$OUTPUT_FILE"

  sleep $INTERVAL
done
```

**Query Performance Analysis: `test/scripts/analyze_db_performance.sql`**

```sql
-- Top 10 slowest queries
SELECT
  query,
  calls,
  mean_exec_time AS avg_ms,
  max_exec_time AS max_ms,
  stddev_exec_time AS stddev_ms,
  total_exec_time / 1000 AS total_sec
FROM pg_stat_statements
WHERE query LIKE '%user_goal_progress%'
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Connection pool utilization
SELECT
  state,
  COUNT(*) as count
FROM pg_stat_activity
GROUP BY state;

-- Table statistics
SELECT
  schemaname,
  tablename,
  n_tup_ins AS inserts,
  n_tup_upd AS updates,
  n_tup_del AS deletes,
  n_live_tup AS live_rows
FROM pg_stat_user_tables
WHERE tablename = 'user_goal_progress';

-- Index usage
SELECT
  indexrelname AS index_name,
  idx_scan AS index_scans,
  idx_tup_read AS tuples_read,
  idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE tablename = 'user_goal_progress';
```

**Running Scenario 4:**

```bash
# Terminal 1: Start k6 test
TARGET_RPS=500 TARGET_EPS=2000 k6 run --web-dashboard --out json=results_scenario4.json test/k6/scenario3_combined.js

# Terminal 2: Start database monitoring
./test/scripts/monitor_db.sh results_scenario4_db.log

# Terminal 3: Watch live query stats
watch -n 5 "psql -U postgres -d challenge_db -c '
  SELECT query, calls, mean_exec_time, max_exec_time
  FROM pg_stat_statements
  WHERE query LIKE \"%user_goal_progress%\"
  ORDER BY mean_exec_time DESC
  LIMIT 5;
'"
```

**After test completes:**

```bash
# Analyze query performance
psql -U postgres -d challenge_db -f test/scripts/analyze_db_performance.sql > results_scenario4_queries.txt

# Reset pg_stat_statements for next test
psql -U postgres -d challenge_db -c "SELECT pg_stat_statements_reset();"
```

---

### Scenario 5: E2E Latency Validation

**Duration:** 5 minutes (short validation test)
**Objective:** Measure end-to-end latency from event to API visibility

**Approach:**
Since buffer flush happens every 1 second, E2E latency is dominated by the flush interval:
- Best case: Event arrives just before flush → ~50ms delay
- Worst case: Event arrives just after flush → ~1,050ms delay
- Average: ~500ms delay

**Test:** Send events, measure event processing time, document flush interval.

**No separate k6 script needed** - just analyze buffer flush logs from event handler during any event test.

**Validation:**

```bash
# Run short event load test
TARGET_EPS=1000 k6 run --duration=5m --web-dashboard test/k6/scenario2_event_load.js

# Check event handler logs for flush timing
docker logs challenge-event-handler 2>&1 | grep "buffer flush"

# Expected output:
# buffer flush: 1,234 updates in 18ms
# buffer flush: 987 updates in 15ms
# buffer flush: 2,101 updates in 23ms
```

**Metrics to document:**
- Event processing time: p50, p95, p99 (from k6)
- Buffer flush time: average, max (from logs)
- E2E latency calculation: processing time + flush interval (~1 second)

---

## Implementation Guide

### Step 1: Update docker-compose.yml

Add resource limits to `docker-compose.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: challenge-postgres
    environment:
      POSTGRES_DB: ${DB_NAME:-challenge_db}
      POSTGRES_USER: ${DB_USER:-postgres}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-postgres}
    ports:
      - "5433:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          cpus: '1.0'
          memory: 2G
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d challenge_db"]
      interval: 10s
      timeout: 5s
      retries: 5
    # Enable pg_stat_statements
    command:
      - "postgres"
      - "-c"
      - "shared_preload_libraries=pg_stat_statements"
      - "-c"
      - "pg_stat_statements.track=all"

  redis:
    image: redis:7-alpine
    container_name: challenge-redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  challenge-service:
    build: ./extend-challenge-service
    image: challenge-service:0.0.1
    container_name: challenge-service
    ports:
      - "6565:6565"  # gRPC
      - "8000:8000"  # gRPC Gateway
      - "8080:8080"  # REST API
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    env_file: .env
    environment:
      - MOCK_AGS=true
      - MOCK_AGS_LATENCY_MIN_MS=50
      - MOCK_AGS_LATENCY_MAX_MS=200
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
    restart: unless-stopped

  challenge-event-handler:
    build: ./extend-challenge-event-handler
    image: challenge-event-handler:0.0.1
    container_name: challenge-event-handler
    ports:
      - "6566:6565"  # gRPC (different host port)
      - "8081:8080"  # Metrics
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    env_file: .env
    environment:
      - BUFFER_FLUSH_INTERVAL=1s
      - BUFFER_SIZE_LIMIT=100000
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
    restart: unless-stopped

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
```

### Step 2: Generate Test Fixtures

**Generate user pool: `test/scripts/generate_users.sh`**

```bash
#!/bin/bash

# Generate 10,000 test users
# Output: test/fixtures/users.json

OUTPUT_FILE="test/fixtures/users.json"
USER_COUNT=10000

echo "Generating $USER_COUNT test users..."

mkdir -p test/fixtures

# Generate JSON array of users
echo "[" > "$OUTPUT_FILE"

for i in $(seq 1 $USER_COUNT); do
  USER_ID=$(printf "user-%06d" $i)

  if [ $i -eq $USER_COUNT ]; then
    echo "  {\"id\": \"$USER_ID\", \"namespace\": \"test\"}" >> "$OUTPUT_FILE"
  else
    echo "  {\"id\": \"$USER_ID\", \"namespace\": \"test\"}," >> "$OUTPUT_FILE"
  fi
done

echo "]" >> "$OUTPUT_FILE"

echo "Generated $USER_COUNT users in $OUTPUT_FILE"
```

**Generate AGS JWT tokens: `test/scripts/generate_tokens.sh`**

```bash
#!/bin/bash

# Generate real AGS IAM tokens for test users
# Output: test/fixtures/tokens.json

AGS_BASE_URL=${AGS_BASE_URL:-"https://demo.accelbyte.io"}
AGS_CLIENT_ID=${AGS_CLIENT_ID}
AGS_CLIENT_SECRET=${AGS_CLIENT_SECRET}
AGS_NAMESPACE=${AGS_NAMESPACE:-"test"}

USER_FILE="test/fixtures/users.json"
OUTPUT_FILE="test/fixtures/tokens.json"

if [ -z "$AGS_CLIENT_ID" ] || [ -z "$AGS_CLIENT_SECRET" ]; then
  echo "Error: AGS_CLIENT_ID and AGS_CLIENT_SECRET must be set"
  exit 1
fi

echo "Generating AGS tokens for users in $USER_FILE..."

# Get OAuth token for service account
ACCESS_TOKEN=$(curl -s -X POST \
  "$AGS_BASE_URL/iam/v3/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "$AGS_CLIENT_ID:$AGS_CLIENT_SECRET" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Error: Failed to get OAuth token"
  exit 1
fi

# Generate user tokens (24-hour expiration)
# Note: This is a placeholder - actual implementation depends on AGS API
# You may need to create test users first via AGS Admin API

echo "[]" > "$OUTPUT_FILE"

echo "Token generation complete: $OUTPUT_FILE"
echo "Tokens valid for 24 hours"
```

**Create challenge config: `test/fixtures/challenges.json`**

```json
{
  "challenges": [
    {
      "id": "challenge-001",
      "name": "Daily Login Streak",
      "description": "Login every day for rewards",
      "goals": [
        {
          "id": "login-1",
          "name": "Login 1 Time",
          "requirement": {
            "stat_code": "login_count",
            "operator": ">=",
            "target_value": 1
          },
          "reward": {
            "type": "WALLET",
            "reward_id": "GEMS",
            "quantity": 10
          }
        },
        {
          "id": "login-7",
          "name": "Login 7 Times",
          "requirement": {
            "stat_code": "login_count",
            "operator": ">=",
            "target_value": 7
          },
          "reward": {
            "type": "WALLET",
            "reward_id": "GEMS",
            "quantity": 100
          }
        }
      ]
    }
  ]
}
```

(Repeat similar structure for 10 challenges, 50 goals each)

### Step 3: Project Structure

```
test/
├── k6/
│   ├── scenario1_api_load.js
│   ├── scenario2_event_load.js
│   ├── scenario3_combined.js
│   └── helpers/
│       ├── common.js
│       └── proto/  # gRPC proto files for k6
├── fixtures/
│   ├── users.json           # 10,000 test users
│   ├── tokens.json          # JWT tokens (24-hour expiration)
│   └── challenges.json      # 10 challenges, 50 goals each
├── scripts/
│   ├── generate_users.sh
│   ├── generate_tokens.sh
│   ├── monitor_db.sh
│   ├── analyze_db_performance.sql
│   └── run_all_scenarios.sh
└── results/
    ├── scenario1/
    ├── scenario2/
    ├── scenario3/
    ├── scenario4/
    └── scenario5/
```

---

## Execution Procedures

### Pre-Test Setup

1. **Start services:**
   ```bash
   docker-compose up -d
   docker-compose logs -f  # Verify services healthy
   ```

2. **Enable pg_stat_statements:**
   ```bash
   psql -U postgres -d challenge_db -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
   ```

3. **Generate test fixtures:**
   ```bash
   ./test/scripts/generate_users.sh
   ./test/scripts/generate_tokens.sh
   ```

4. **Load challenge config:**
   ```bash
   cp test/fixtures/challenges.json extend-challenge-service/config/challenges.json
   docker-compose restart challenge-service challenge-event-handler
   ```

5. **Verify system health:**
   ```bash
   curl http://localhost:8080/healthz
   # Expected: {"status": "ok"}
   ```

### Running Tests

**Scenario 1: API Load (Isolated)**

```bash
# Create results directory
mkdir -p test/results/scenario1

# Test each load level
for RPS in 50 100 200 500 1000 2000 5000; do
  echo "Testing API load at $RPS RPS..."

  TARGET_RPS=$RPS k6 run \
    --web-dashboard \
    --out json=test/results/scenario1/level_${RPS}rps.json \
    test/k6/scenario1_api_load.js

  # Check if test passed thresholds
  if [ $? -ne 0 ]; then
    echo "Test FAILED at $RPS RPS - System at limit"
    break
  fi

  # Cool down between tests
  sleep 60

  # Reset database for next test
  psql -U postgres -d challenge_db -c "TRUNCATE TABLE user_goal_progress;"
done
```

**Scenario 2: Event Load (Isolated)**

```bash
mkdir -p test/results/scenario2

for EPS in 100 500 1000 2000 5000 10000; do
  echo "Testing event load at $EPS EPS..."

  TARGET_EPS=$EPS k6 run \
    --web-dashboard \
    --out json=test/results/scenario2/level_${EPS}eps.json \
    test/k6/scenario2_event_load.js

  if [ $? -ne 0 ]; then
    echo "Test FAILED at $EPS EPS - System at limit"
    break
  fi

  sleep 60
  psql -U postgres -d challenge_db -c "TRUNCATE TABLE user_goal_progress;"
done
```

**Scenario 3: Combined Load**

```bash
mkdir -p test/results/scenario3

# Test matrix: API RPS × Event EPS
API_LEVELS=(50 100 200 500 1000)
EVENT_LEVELS=(100 500 1000 2000 5000)

for RPS in "${API_LEVELS[@]}"; do
  for EPS in "${EVENT_LEVELS[@]}"; do
    echo "Testing combined load: $RPS RPS + $EPS EPS..."

    # Start profiling in background
    go tool pprof -text http://localhost:8080/debug/pprof/profile?seconds=30 > test/results/scenario3/cpu_${RPS}rps_${EPS}eps.txt 2>&1 &

    TARGET_RPS=$RPS TARGET_EPS=$EPS k6 run \
      --web-dashboard \
      --out json=test/results/scenario3/level_${RPS}rps_${EPS}eps.json \
      test/k6/scenario3_combined.js

    if [ $? -ne 0 ]; then
      echo "Test FAILED at $RPS RPS + $EPS EPS - System at limit"
      break 2
    fi

    # Collect memory profile
    go tool pprof -text http://localhost:8080/debug/pprof/heap > test/results/scenario3/heap_${RPS}rps_${EPS}eps.txt 2>&1

    sleep 60
    psql -U postgres -d challenge_db -c "TRUNCATE TABLE user_goal_progress;"
  done
done
```

**Scenario 4: Database Deep Dive**

```bash
mkdir -p test/results/scenario4

RPS=500
EPS=2000

echo "Testing with database monitoring: $RPS RPS + $EPS EPS..."

# Start database monitoring
./test/scripts/monitor_db.sh test/results/scenario4/db_monitor.log &
MONITOR_PID=$!

# Reset pg_stat_statements
psql -U postgres -d challenge_db -c "SELECT pg_stat_statements_reset();"

# Run test
TARGET_RPS=$RPS TARGET_EPS=$EPS k6 run \
  --web-dashboard \
  --out json=test/results/scenario4/results.json \
  test/k6/scenario3_combined.js

# Stop monitoring
kill $MONITOR_PID

# Analyze queries
psql -U postgres -d challenge_db -f test/scripts/analyze_db_performance.sql > test/results/scenario4/query_analysis.txt
```

**Scenario 5: E2E Latency**

```bash
mkdir -p test/results/scenario5

# Short 5-minute test
TARGET_EPS=1000 k6 run \
  --duration=5m \
  --web-dashboard \
  --out json=test/results/scenario5/results.json \
  test/k6/scenario2_event_load.js

# Check event handler logs for buffer flush timing
docker logs challenge-event-handler 2>&1 | grep "buffer flush" > test/results/scenario5/flush_timing.log
```

### Progress Tracking

Create a progress log: `test/results/progress.md`

```markdown
# M2 Load Testing Progress

## Scenario 1: API Load (Isolated)

- [x] Level 1: 50 RPS - ✅ PASSED (p95=45ms, error=0%)
- [x] Level 2: 100 RPS - ✅ PASSED (p95=67ms, error=0%)
- [x] Level 3: 200 RPS - ✅ PASSED (p95=123ms, error=0.1%)
- [x] Level 4: 500 RPS - ⚠️ WARNING (p95=456ms, error=0.5%)
- [x] Level 5: 1,000 RPS - ❌ FAILED (p95=2,341ms, error=3.2%)
- [ ] Maximum: 500 RPS (with 0.5% error acceptable)

## Scenario 2: Event Load (Isolated)

- [x] Level 1: 100 EPS - ✅ PASSED (p95=12ms, error=0%)
- [x] Level 2: 500 EPS - ✅ PASSED (p95=34ms, error=0%)
- [x] Level 3: 1,000 EPS - ✅ PASSED (p95=78ms, error=0.1%)
- [x] Level 4: 2,000 EPS - ⚠️ WARNING (p95=234ms, error=0.8%)
- [ ] Level 5: 5,000 EPS - Testing...

## Scenario 3: Combined Load

- [x] 50 RPS + 100 EPS - ✅ PASSED
- [x] 100 RPS + 500 EPS - ✅ PASSED
- [x] 200 RPS + 1,000 EPS - ⚠️ WARNING
- [ ] 500 RPS + 2,000 EPS - Pending...

## Bottlenecks Identified

1. Database connection pool saturated at >500 RPS
2. Buffer flush time increases linearly with event rate
3. CPU becomes bottleneck at combined load >300 RPS + 1500 EPS

## Next Steps

- [ ] Test increased DB connection pool (100 connections)
- [ ] Profile memory allocations during peak load
- [ ] Test with buffer flush interval at 2 seconds
```

---

## Metrics Collection

### From k6 Dashboard

Access at `http://localhost:5665` during test run.

**HTTP Metrics:**
- `http_req_duration` - Response time (p50, p95, p99)
- `http_reqs` - Total requests and rate (RPS)
- `http_req_failed` - Error rate (%)
- `http_req_blocked` - Time blocked waiting for connection
- `http_req_connecting` - Time establishing TCP connection
- `http_req_sending` - Time sending request
- `http_req_waiting` - Time waiting for response (TTFB)
- `http_req_receiving` - Time receiving response

**gRPC Metrics:**
- `grpc_req_duration` - gRPC call duration (p50, p95, p99)
- `grpc_streams` - Active streams
- `checks` - Success rate of assertions

**System Metrics:**
- `vus` - Active virtual users
- `vus_max` - Maximum VUs allocated
- `data_sent` - Total data sent
- `data_received` - Total data received
- `iteration_duration` - Time per iteration

### From Docker Stats

```bash
# Monitor resource usage
docker stats --no-stream challenge-service challenge-event-handler postgres

# Expected output columns:
# CONTAINER           CPU %     MEM USAGE / LIMIT     MEM %     NET I/O
# challenge-service   87.5%     823MB / 1GB          82.3%     1.2GB / 856MB
# event-handler       45.2%     512MB / 1GB          51.2%     3.4GB / 234MB
# postgres            65.8%     2.1GB / 4GB          52.5%     1.8GB / 1.5GB
```

### From Go pprof

**CPU Profile:**
```bash
go tool pprof -text http://localhost:8080/debug/pprof/profile?seconds=30

# Top CPU consumers:
# Showing nodes accounting for 2.85s, 71.25% of 4s total
# 0.95s (23.75%) runtime.mallocgc
# 0.45s (11.25%) database/sql.(*DB).queryDC
# 0.38s (9.50%)  encoding/json.Unmarshal
```

**Memory Profile:**
```bash
go tool pprof -text http://localhost:8080/debug/pprof/heap

# Top memory allocations:
# Showing nodes accounting for 412.5MB, 82.5% of 500MB total
# 125MB (25%) buffer.(*Buffer).Flush
# 87.5MB (17.5%) http.(*conn).serve
# 62.5MB (12.5%) grpc.(*Server).handleStream
```

**Goroutine Profile:**
```bash
go tool pprof -text http://localhost:8080/debug/pprof/goroutine

# Active goroutines:
# goroutine profile: total 1247
# 523 @ grpc.(*Server).handleStream
# 345 @ database/sql.(*DB).connectionOpener
# 234 @ http.(*conn).serve
```

### From PostgreSQL

**Query Statistics:**
```sql
SELECT
  query,
  calls,
  mean_exec_time AS avg_ms,
  max_exec_time AS max_ms,
  total_exec_time / 1000 AS total_sec,
  100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0) AS cache_hit_ratio
FROM pg_stat_statements
WHERE query LIKE '%user_goal_progress%'
ORDER BY mean_exec_time DESC
LIMIT 10;
```

**Connection Pool:**
```sql
SELECT
  state,
  COUNT(*) as count,
  MAX(EXTRACT(EPOCH FROM (now() - state_change))) as oldest_sec
FROM pg_stat_activity
GROUP BY state;

-- Expected output:
--  state    | count | oldest_sec
-- ----------+-------+------------
--  active   |   45  |    0.234
--  idle     |    5  |   12.567
```

**Table Statistics:**
```sql
SELECT
  pg_size_pretty(pg_total_relation_size('user_goal_progress')) AS total_size,
  n_live_tup AS live_rows,
  n_dead_tup AS dead_rows,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE tablename = 'user_goal_progress';
```

---

## Analysis and Reporting

### Performance Baseline Report

**Template: `docs/PERFORMANCE_BASELINE.md`**

```markdown
# Performance Baseline Report - M2

**Test Date:** 2025-10-23
**Test Duration:** 2 weeks
**Environment:** Local docker-compose
**Resources:** 1 CPU / 1 GB per service, 2 CPU / 4 GB database

---

## Executive Summary

Maximum sustainable capacity under resource constraints:
- **API Requests:** 500 RPS (p95 < 500ms, error < 1%)
- **Event Processing:** 2,000 EPS (p95 < 200ms, error < 1%)
- **Combined Load:** 200 RPS + 1,000 EPS

Primary bottleneck: Database connection pool saturation

---

## Scenario 1: API Load (Isolated)

### Test Results

| RPS   | p50   | p95   | p99    | Error Rate | CPU %  | Memory |
|-------|-------|-------|--------|-----------|--------|--------|
| 50    | 23ms  | 45ms  | 78ms   | 0%        | 12%    | 234MB  |
| 100   | 34ms  | 67ms  | 123ms  | 0%        | 23%    | 312MB  |
| 200   | 56ms  | 123ms | 234ms  | 0.1%      | 45%    | 456MB  |
| 500   | 123ms | 456ms | 892ms  | 0.5%      | 87%    | 723MB  |
| 1000  | 567ms | 2341ms| 4567ms | 3.2%      | 98%    | 891MB  |

### Maximum Capacity

- **Recommended:** 500 RPS (with 0.5% error tolerance)
- **Conservative:** 200 RPS (for <0.1% error rate)

### Bottleneck Analysis

At 1,000 RPS:
- Database connection pool exhausted (50/50 active)
- Average wait time for connection: 234ms
- CPU at 98% (mostly spent in database/sql.(*DB).queryDC)

### Optimization Recommendations

1. Increase DB connection pool to 100
2. Add connection pooling layer (PgBouncer)
3. Implement API response caching (Redis)
4. Horizontal scaling (2+ backend instances)

---

## Scenario 2: Event Load (Isolated)

[Similar structure...]

---

## Scenario 3: Combined Load

[Similar structure...]

---

## Bottleneck Summary

1. **Database Connection Pool** (Primary)
   - Pool saturated at >500 RPS API load
   - Connections held for avg 45ms per request
   - Recommendation: Increase to 100-150 connections

2. **CPU Utilization** (Secondary)
   - 1 CPU insufficient for >1,000 RPS + 2,000 EPS combined
   - Hotspots: JSON serialization, database queries
   - Recommendation: 2 CPUs or horizontal scaling

3. **Memory Allocation** (Minor)
   - GC cycles increase at high load (20ms pause every 500ms)
   - Memory usage stable (no leaks detected)
   - Recommendation: Monitor in production, current limits OK

---

## Scaling Recommendations

### Vertical Scaling

**Configuration A: 2 CPU / 2 GB**
- Expected capacity: 1,000-1,500 RPS + 3,000-5,000 EPS
- Cost: 2x current
- Use case: Simple deployment, predictable load

**Configuration B: 4 CPU / 4 GB**
- Expected capacity: 2,000-3,000 RPS + 8,000-10,000 EPS
- Cost: 4x current
- Use case: High load, vertical scaling preferred

### Horizontal Scaling

**Configuration C: 3 instances @ 1 CPU / 1 GB each**
- Expected capacity: 1,500 RPS + 6,000 EPS (3x single instance)
- Cost: 3x current
- Use case: High availability, load distribution
- Requires: Load balancer, shared database

---

## Conclusions

The Challenge Service can handle moderate load (500 RPS + 2,000 EPS) on minimal resources (1 CPU / 1 GB). Primary bottleneck is database connection pool, which is easily addressable via configuration or external pooling.

For production deployment with expected load >1,000 RPS:
- Recommended: Horizontal scaling (3+ instances)
- Database: Increase connection pool to 150-200
- Monitoring: Alert on connection pool utilization >80%
```

### Capacity Planning Guide

**Template: `docs/CAPACITY_PLANNING.md`**

```markdown
# Capacity Planning Guide - M2

## Deployment Scenarios

### Scenario 1: Small Game (<10,000 DAU)

**Expected Load:**
- 50-100 RPS
- 500-1,000 EPS
- Peak concurrent users: 500

**Recommended Configuration:**
- Backend Service: 1 CPU, 1 GB RAM
- Event Handler: 1 CPU, 1 GB RAM
- Database: 2 CPU, 4 GB RAM
- Connection pool: 50

**Monthly Cost (AWS):** ~$150

---

### Scenario 2: Medium Game (100,000 DAU)

**Expected Load:**
- 500-1,000 RPS
- 5,000-10,000 EPS
- Peak concurrent users: 5,000

**Recommended Configuration:**
- Backend Service: 3 instances @ 2 CPU, 2 GB RAM each
- Event Handler: 2 instances @ 2 CPU, 2 GB RAM each
- Database: 4 CPU, 8 GB RAM (RDS)
- Connection pool: 150
- Load balancer: ALB

**Monthly Cost (AWS):** ~$800

---

### Scenario 3: Large Game (1,000,000 DAU)

**Expected Load:**
- 2,000-5,000 RPS
- 20,000-50,000 EPS
- Peak concurrent users: 50,000

**Recommended Configuration:**
- Backend Service: 10 instances @ 2 CPU, 4 GB RAM each
- Event Handler: 5 instances @ 4 CPU, 4 GB RAM each
- Database: Aurora PostgreSQL (4 instances, 8 CPU, 16 GB RAM each)
- Connection pool: 300 per instance
- Load balancer: ALB with auto-scaling
- Cache: Redis cluster (3 nodes)

**Monthly Cost (AWS):** ~$5,000

---

## Scaling Decision Tree

```
Start: What's your expected peak RPS?

< 500 RPS
  └─> 1 instance (1 CPU, 1 GB)

500-1,000 RPS
  └─> 2 instances (2 CPU, 2 GB each) OR 1 instance (4 CPU, 4 GB)

1,000-5,000 RPS
  └─> 5-10 instances (2 CPU, 2 GB each) + load balancer

> 5,000 RPS
  └─> 10+ instances + auto-scaling + Redis cache + read replicas
```

---

## Cost-Performance Trade-offs

| Configuration | Cost | RPS Capacity | EPS Capacity | Reliability |
|--------------|------|-------------|-------------|-------------|
| 1×(1CPU,1GB) | $    | 500         | 2,000       | Low         |
| 1×(4CPU,4GB) | $$   | 2,000       | 8,000       | Low         |
| 3×(2CPU,2GB) | $$$  | 1,500       | 6,000       | High        |
| 10×(2CPU,2GB)| $$$$$| 5,000       | 20,000      | Very High   |

**Recommendation:** Horizontal scaling (multiple instances) preferred for reliability, vertical scaling (larger instances) for simplicity.
```

### Performance Tuning Guide

**Template: `docs/PERFORMANCE_TUNING.md`**

```markdown
# Performance Tuning Guide - M2

## Configuration Optimizations

### 1. Database Connection Pool

**Current:** 50 connections
**Recommended:** 100-150 connections for high load

**Update `.env`:**
```
DB_MAX_OPEN_CONNS=100
DB_MAX_IDLE_CONNS=25
DB_CONN_MAX_LIFETIME=30m
DB_CONN_MAX_IDLE_TIME=5m
```

**Rationale:** Load tests showed pool saturation at >500 RPS. Increasing to 100 provides headroom.

---

### 2. Buffer Flush Interval

**Current:** 1 second
**Consider:** 2-5 seconds for very high event load (>10,000 EPS)

**Trade-off:**
- Lower interval (0.5s): Better E2E latency, more DB writes
- Higher interval (5s): Worse E2E latency, fewer DB writes (better throughput)

**Recommendation:** Keep at 1 second unless throughput becomes bottleneck.

---

### 3. PostgreSQL Configuration

**Tuning for performance:**

```sql
-- postgresql.conf
shared_buffers = 2GB              -- 25% of RAM
effective_cache_size = 6GB        -- 75% of RAM
maintenance_work_mem = 512MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1            -- For SSD
effective_io_concurrency = 200    -- For SSD
work_mem = 10MB
min_wal_size = 1GB
max_wal_size = 4GB
max_connections = 200
```

**Enable query performance:**
```sql
CREATE EXTENSION pg_stat_statements;
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
```

---

### 4. Index Optimization

**Verified indexes:**
```sql
-- Primary key (already exists)
ALTER TABLE user_goal_progress ADD PRIMARY KEY (user_id, goal_id);

-- Composite index for challenge queries
CREATE INDEX IF NOT EXISTS idx_user_challenge
ON user_goal_progress(user_id, challenge_id);

-- Partial index for unclaimed completed goals
CREATE INDEX IF NOT EXISTS idx_completed_unclaimed
ON user_goal_progress(user_id, status)
WHERE status = 'completed' AND claimed_at IS NULL;
```

**Verify index usage:**
```sql
EXPLAIN ANALYZE
SELECT * FROM user_goal_progress
WHERE user_id = 'user-000123';

-- Should show: Index Scan using user_goal_progress_pkey
```

---

## Code-Level Optimizations

### 1. Reduce JSON Allocations

**Current bottleneck:** JSON unmarshaling in hot path

**Optimization:** Use `json.RawMessage` for partial parsing

**Before:**
```go
var fullPayload ChallengeResponse
json.Unmarshal(data, &fullPayload)
```

**After:**
```go
var partial struct {
    Challenges json.RawMessage `json:"challenges"`
}
json.Unmarshal(data, &partial)
// Only unmarshal challenges if needed
```

---

### 2. Connection Pool Pre-warming

**Add to service startup:**
```go
// Warm up connection pool on startup
for i := 0; i < 10; i++ {
    go func() {
        _, err := db.Exec("SELECT 1")
        if err != nil {
            log.Warn("Connection pool warm-up failed", "error", err)
        }
    }()
}
```

---

### 3. Mutex Granularity

**Current:** Per-user mutex (good)
**Verify:** No lock contention at high concurrency

**Check with pprof:**
```bash
go tool pprof -text http://localhost:8080/debug/pprof/mutex

# If high contention, consider:
# - sync.Map for user buffers
# - Sharded mutexes (user_id % 256)
```

---

## Monitoring Alerts

**Set up alerts for:**

1. **Connection Pool Saturation**
   ```
   db_connections_active / db_connections_max > 0.8
   ```

2. **High API Latency**
   ```
   http_request_duration_p95 > 500ms
   ```

3. **High Event Processing Latency**
   ```
   grpc_request_duration_p95 > 100ms
   ```

4. **Error Rate Spike**
   ```
   http_errors_rate > 0.01  (1%)
   ```

---

## Load Testing in Production

**Use k6 cloud for distributed load testing:**

```bash
# Run from multiple regions
k6 cloud test/k6/scenario1_api_load.js

# Ramp up gradually
export K6_CLOUD_PROJECT_ID=your-project-id
k6 cloud run --vus 10 --duration 5m test/k6/scenario1_api_load.js
```

**Monitor during production load:**
```bash
# Real-time dashboard
watch -n 1 'docker stats --no-stream'

# Query performance
watch -n 5 'psql -c "SELECT * FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5"'
```
```

---

## Deliverables

### 1. Performance Baseline Report

**File:** `docs/PERFORMANCE_BASELINE.md`
**Pages:** 5-10
**Content:**
- Maximum RPS achieved (by scenario)
- Maximum EPS achieved (by scenario)
- Maximum combined load
- Bottleneck identification with evidence
- Resource utilization graphs

**Format:**
- Executive summary (1 page)
- Detailed results per scenario (1-2 pages each)
- Bottleneck analysis (1-2 pages)
- Conclusions and recommendations (1 page)

---

### 2. Capacity Planning Guide

**File:** `docs/CAPACITY_PLANNING.md`
**Pages:** 5-10
**Content:**
- Deployment scenarios (small, medium, large games)
- Resource recommendations per scenario
- Cost estimates (AWS/GCP/Azure)
- Scaling decision tree
- Cost-performance trade-offs

**Format:**
- Scenario templates (1 page per scenario)
- Decision tree diagram
- Cost comparison table
- Scaling strategies

---

### 3. Performance Tuning Guide

**File:** `docs/PERFORMANCE_TUNING.md`
**Pages:** 5-10
**Content:**
- Configuration optimizations discovered
- Database tuning recommendations
- Code-level improvements identified
- Monitoring and alerting setup
- Production load testing guide

**Format:**
- Configuration sections (grouped by service)
- Code optimization examples
- Monitoring alert templates
- Best practices checklist

---

## Timeline

### Week 1: Setup and Initial Testing

- **Day 1-2:** Setup
  - Update docker-compose.yml with resource limits
  - Generate test fixtures (users, tokens, challenges)
  - Install k6 and verify setup

- **Day 3-5:** Initial Tests
  - Run Scenario 1 (API load) at all levels
  - Run Scenario 2 (Event load) at all levels
  - Document baseline results

### Week 2: Combined Testing and Analysis

- **Day 6-8:** Combined Tests
  - Run Scenario 3 (combined load) at matrix of levels
  - Collect CPU/memory profiles
  - Run Scenario 4 (DB deep dive)
  - Run Scenario 5 (E2E latency)

- **Day 9-11:** Analysis and Optimization (if time permits)
  - Identify top 3 bottlenecks
  - Attempt 1-2 optimization passes
  - Re-test after optimizations

- **Day 12-14:** Documentation
  - Write Performance Baseline Report
  - Write Capacity Planning Guide
  - Write Performance Tuning Guide

**Total:** 2-3 weeks (flexible, no hard deadline)

---

## Success Checklist

- [ ] Docker resource limits configured
- [ ] Test fixtures generated (users, tokens, challenges)
- [ ] k6 installed and scripts written
- [ ] Scenario 1 complete (all load levels tested)
- [ ] Scenario 2 complete (all load levels tested)
- [ ] Scenario 3 complete (combined load matrix tested)
- [ ] Scenario 4 complete (database analysis done)
- [ ] Scenario 5 complete (E2E latency measured)
- [ ] CPU profiling collected
- [ ] Memory profiling collected
- [ ] Database query analysis done
- [ ] Bottlenecks identified (top 3 minimum)
- [ ] Performance Baseline Report written
- [ ] Capacity Planning Guide written
- [ ] Performance Tuning Guide written
- [ ] Results reviewed and validated

---

## References

- [MILESTONES.md](./MILESTONES.md) - M2 overview and goals
- [BRAINSTORM_M2.md](./BRAINSTORM_M2.md) - Design decisions
- [k6 Documentation](https://k6.io/docs/)
- [k6 Web Dashboard](https://grafana.com/docs/k6/latest/results-output/web-dashboard/)
- [PostgreSQL Performance Tuning](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [Go pprof Guide](https://go.dev/blog/pprof)

---

**Document Status:** Final - Ready for Implementation
