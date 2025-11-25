# Scenario 4: M4 Realistic User Sessions

## Overview

**Purpose:** Load test M4 features (batch and random goal selection) with **realistic sequential user journeys**.

**Key Difference from Scenario 3:**
- Scenario 3: Random API calls, tests general system load
- **Scenario 4: Sequential per-user sessions, tests M4 workflow**

## What It Tests

### Realistic User Journey (per VU)

Each virtual user goes through this **complete sequential flow**:

```
1. 🚀 Initialize         (GET /initialize)
2. 👀 Browse Challenges  (GET /v1/challenges)
3. 🎯 Select Goals       (POST batch-select OR random-select) ← M4 NEW
4. 🎲 Play Game          (simulated with sleep, events in background)
5. 📊 Check Progress     (GET /v1/challenges/{id})
6. 🏆 Claim Reward       (POST claim) - 30% of sessions
7. ♻️  Repeat
```

### M4 Features Under Test

- **Batch Manual Selection** (`POST /goals/batch-select`)
  - 40% of users manually select 3 goals
  - Tests `BatchUpsertGoalActive` performance

- **Random Selection** (`POST /goals/random-select`)
  - 60% of users use "Surprise Me" for 5 random goals
  - Tests random algorithm + batch operations
  - Tests `exclude_active` filtering

### Load Pattern

**User Sessions:**
- 150 concurrent users (VUs)
- Each user completes 120 sessions in 30 minutes
- Each session = complete journey (6-8 API calls)
- **Result:** ~300 RPS aggregate across all endpoints

**Background Events:**
- 500 events/second (gRPC)
- 20% login events
- 80% stat updates
- Simulates continuous gameplay

## Performance Targets

### M4-Specific (Strict)
- `batch-select` p95 < **50ms**
- `random-select` p95 < **50ms**

### Other Endpoints
- `/initialize` p95 < 100ms
- `/v1/challenges` p95 < 500ms
- `/claim` p95 < 100ms

### Overall System
- HTTP requests p95 < 2000ms
- gRPC events p95 < 500ms
- Success rate > 99%
- Error rate < 1%

## How to Run

### Prerequisites

1. **Services running:**
   ```bash
   # Backend service at http://localhost:8000/challenge
   # Event handler at localhost:6566
   ```

2. **Test fixtures:**
   ```bash
   # tests/loadtest/fixtures/tokens.json - user JWT tokens
   # tests/loadtest/fixtures/users.json - user data
   ```

### Basic Run

```bash
cd tests/loadtest/k6
k6 run scenario4_m4_realistic_sessions.js
```

### Custom Configuration

```bash
# Adjust concurrent users
k6 run \
  -e TARGET_VUS=200 \
  -e ITERATIONS=90 \
  scenario4_m4_realistic_sessions.js

# Adjust event load
k6 run \
  -e TARGET_EPS=1000 \
  scenario4_m4_realistic_sessions.js

# Custom challenge ID
k6 run \
  -e CHALLENGE_ID=weekly-challenges \
  scenario4_m4_realistic_sessions.js

# Different backend URL
k6 run \
  -e BASE_URL=http://staging.example.com/challenge \
  scenario4_m4_realistic_sessions.js
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://localhost:8000/challenge` | Backend service URL |
| `EVENT_HANDLER_ADDR` | `localhost:6566` | Event handler gRPC address |
| `TARGET_VUS` | `150` | Concurrent users (VUs) |
| `ITERATIONS` | `120` | Sessions per user |
| `TARGET_EPS` | `500` | Events per second |
| `NAMESPACE` | `test` | AGS namespace |
| `CHALLENGE_ID` | `daily-challenges` | Challenge ID for tests |

### Example: High Load Test

```bash
# 300 concurrent users, 1000 events/sec
k6 run \
  -e TARGET_VUS=300 \
  -e ITERATIONS=60 \
  -e TARGET_EPS=1000 \
  scenario4_m4_realistic_sessions.js
```

## Interpreting Results

### Success Criteria

✅ **All checks pass (>99% success rate)**
```
✓ Initialize: status 200
✓ Browse: has challenges
✓ Batch Select: p95 < 50ms
✓ Random Select: p95 < 50ms
✓ Event: stat OK
```

✅ **M4 performance within targets**
```
http_req_duration{endpoint:batch_select}...: avg=25ms p95=45ms
http_req_duration{endpoint:random_select}..: avg=22ms p95=48ms
```

✅ **Overall system healthy**
```
http_req_duration.........................: avg=120ms p95=450ms
http_req_failed............................: 0.12%
checks.....................................: 99.87%
```

### Warning Signs

⚠️ **M4 performance degradation:**
```
http_req_duration{endpoint:batch_select}...: p95=85ms  ← OVER 50ms target
```

⚠️ **Database contention:**
```
http_req_duration{endpoint:claim}..........: p95=350ms  ← Slow claims
```

⚠️ **High error rate:**
```
http_req_failed............................: 5.2%  ← > 1% threshold
```

## Load Calculation

### RPS Calculation

```
VUs × Requests per Session / Average Session Duration = RPS

150 VUs × 7 requests / ~30 seconds = ~35 RPS per stage
Total stages running concurrently = variable distribution
Aggregate RPS ≈ 200-300 RPS
```

### Adjusting Load

**To increase RPS:**
1. Increase `TARGET_VUS` (more concurrent users)
2. Reduce sleep times in `userSession()` (faster sessions)
3. Increase `ITERATIONS` (more sessions per user)

**To decrease RPS:**
1. Decrease `TARGET_VUS`
2. Increase sleep times (slower sessions)
3. Decrease `ITERATIONS`

## Comparing with Scenario 3

| Aspect | Scenario 3 | Scenario 4 |
|--------|-----------|-----------|
| **Pattern** | Random API calls | Sequential user journeys |
| **Focus** | General system load | M4 workflow validation |
| **User Behavior** | Unrealistic | Realistic |
| **M4 Testing** | No | Yes |
| **Database State** | Random | Realistic (select → progress → claim) |
| **Bug Detection** | System-level | Workflow-level |
| **Use Case** | Stress testing | Feature validation |

## When to Use Scenario 4

✅ **Use Scenario 4 when:**
- Validating M4 features (batch/random selection)
- Testing realistic user workflows
- Measuring session-based metrics
- Testing goal selection → completion → claim flow
- Performance testing under realistic load

❌ **Use Scenario 3 instead when:**
- Pure stress testing (max RPS)
- Testing individual endpoints in isolation
- General system health checks
- No M4 features involved

## Troubleshooting

### Issue: Low RPS (< 200)

**Solution:** Reduce sleep times or increase VUs
```bash
# Faster sessions
k6 run -e TARGET_VUS=200 scenario4_m4_realistic_sessions.js
```

### Issue: M4 endpoints failing (400/404)

**Possible causes:**
1. Challenge ID doesn't exist
2. Goal IDs in `batchSelectGoals()` don't match config
3. Backend service not running

**Solution:** Check challenge configuration
```bash
# Verify challenge exists
curl http://localhost:8000/challenge/v1/challenges/daily-challenges
```

### Issue: Events failing

**Possible causes:**
1. Event handler not running
2. gRPC proto files missing
3. Wrong event handler address

**Solution:** Check event handler
```bash
# Verify event handler running
grpcurl -plaintext localhost:6566 list
```

### Issue: Token authentication failures

**Possible causes:**
1. Tokens expired
2. Wrong namespace
3. Missing tokens.json

**Solution:** Regenerate tokens
```bash
# Generate fresh test tokens
# (implementation-specific, see test fixture generation docs)
```

## Architecture Notes

### Per-VU Iterations Executor

- Each VU maintains state across iterations
- VU #1 does iteration 1, 2, 3... sequentially
- All VUs run in parallel at different stages
- Creates natural distribution across endpoints

### Why Sequential Works Better

**Individual user (VU #42):**
```
Time: 0s   → initialize
Time: 2s   → browse
Time: 6s   → select goals (M4)
Time: 11s  → check progress
Time: 16s  → claim
Time: 26s  → [next iteration starts]
```

**Aggregate view (150 VUs):**
```
Time: 10s
- VU #1:  claiming (45s into session)
- VU #2:  selecting goals (6s into session)
- VU #3:  browsing (2s into session)
- VU #42: checking progress (11s into session)
- VU #99: initializing (0s into session)
```

**Result:** Natural distribution + realistic workflow!

## Extending the Scenario

### Adding New Endpoints

1. Add helper function:
```javascript
function myNewEndpoint(token) {
  const resp = http.post(`${BASE_URL}/v1/my-endpoint`, payload, {
    headers: { 'Authorization': `Bearer ${token}` },
    tags: { endpoint: 'my_endpoint' },
  });

  check(resp, {
    'MyEndpoint: status 200': (r) => r.status === 200,
  });
}
```

2. Add to `userSession()` flow:
```javascript
export function userSession() {
  // ... existing steps ...
  myNewEndpoint(token);
  sleep(randomBetween(1, 2));
}
```

3. Add threshold:
```javascript
thresholds: {
  'http_req_duration{endpoint:my_endpoint}': ['p(95)<100'],
}
```

### Testing Replace Mode

To test `replace_existing=true`:

```javascript
function randomSelectGoals(token) {
  const payload = JSON.stringify({
    count: 5,
    replace_existing: true,  // ← Change this
    exclude_active: true,
  });
  // ... rest of function
}
```

## Related Documentation

- [TECH_SPEC_M4.md](../../../docs/TECH_SPEC_M4.md) - M4 feature specification
- [scenario3_combined.js](./scenario3_combined.js) - Random load testing
- [Performance Testing Guide](../../../docs/TECH_SPEC_TESTING.md) - Overall test strategy
