# Performance Baseline Report - M2

**Test Date:** [FILL IN]
**Test Duration:** [FILL IN]
**Environment:** Local docker-compose
**Resources:** 1 CPU / 1 GB per service, 2 CPU / 4 GB database

---

## Executive Summary

Maximum sustainable capacity under resource constraints:
- **API Requests:** [FILL IN] RPS (p95 < 500ms, error < 1%)
- **Event Processing:** [FILL IN] EPS (p95 < 200ms, error < 1%)
- **Combined Load:** [FILL IN] RPS + [FILL IN] EPS

Primary bottleneck: [FILL IN]

---

## Scenario 1: API Load (Isolated)

### Test Results

| RPS   | p50   | p95   | p99    | Error Rate | CPU %  | Memory |
|-------|-------|-------|--------|-----------|--------|--------|
| 50    | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] |
| 100   | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] |
| 200   | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] |
| 500   | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] |
| 1000  | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] |

### Maximum Capacity

- **Recommended:** [FILL IN] RPS (with acceptable error tolerance)
- **Conservative:** [FILL IN] RPS (for <0.1% error rate)

### Bottleneck Analysis

At [FILL IN] RPS:
- [Describe what happened - CPU, memory, database, etc.]
- [Evidence from metrics]

### Optimization Recommendations

1. [FILL IN]
2. [FILL IN]
3. [FILL IN]
4. [FILL IN]

---

## Scenario 2: Event Load (Isolated)

### Test Results

| EPS   | p50   | p95   | p99    | Error Rate | CPU %  | Memory | Buffer Size |
|-------|-------|-------|--------|-----------|--------|--------|-------------|
| 100   | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] | [FILL]      |
| 500   | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] | [FILL]      |
| 1000  | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] | [FILL]      |
| 2000  | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] | [FILL]      |
| 5000  | [FILL]| [FILL]| [FILL] | [FILL]    | [FILL] | [FILL] | [FILL]      |

### Maximum Capacity

- **Recommended:** [FILL IN] EPS
- **Conservative:** [FILL IN] EPS

### Bottleneck Analysis

At [FILL IN] EPS:
- [Describe bottleneck]
- [Evidence]

### Buffer Performance

- Average flush time: [FILL IN] ms
- Maximum flush time: [FILL IN] ms
- Average buffer size: [FILL IN] entries
- Maximum buffer size: [FILL IN] entries

### Optimization Recommendations

1. [FILL IN]
2. [FILL IN]
3. [FILL IN]

---

## Scenario 3: Combined Load

### Test Results Matrix

| API RPS | Event EPS | Combined Result | p95 API | p95 Event | Error Rate | Notes |
|---------|-----------|-----------------|---------|-----------|-----------|-------|
| 50      | 100       | [PASS/FAIL]     | [FILL]  | [FILL]    | [FILL]    | [FILL]|
| 100     | 500       | [PASS/FAIL]     | [FILL]  | [FILL]    | [FILL]    | [FILL]|
| 200     | 1000      | [PASS/FAIL]     | [FILL]  | [FILL]    | [FILL]    | [FILL]|
| 500     | 2000      | [PASS/FAIL]     | [FILL]  | [FILL]    | [FILL]    | [FILL]|
| 1000    | 5000      | [PASS/FAIL]     | [FILL]  | [FILL]    | [FILL]    | [FILL]|

### Maximum Combined Capacity

- **Recommended:** [FILL IN] RPS + [FILL IN] EPS
- **Conservative:** [FILL IN] RPS + [FILL IN] EPS

### Resource Contention Analysis

[Describe how API and Event loads interfere with each other]

### CPU Profile Analysis

Top CPU consumers (from pprof):
1. [Function name] - [percentage]%
2. [Function name] - [percentage]%
3. [Function name] - [percentage]%

### Memory Profile Analysis

Top memory allocations (from pprof):
1. [Location] - [size] MB
2. [Location] - [size] MB
3. [Location] - [size] MB

### Optimization Recommendations

1. [FILL IN]
2. [FILL IN]
3. [FILL IN]

---

## Scenario 4: Database Performance

### Query Performance

Top 5 slowest queries:
1. [Query] - avg: [FILL] ms, max: [FILL] ms, calls: [FILL]
2. [Query] - avg: [FILL] ms, max: [FILL] ms, calls: [FILL]
3. [Query] - avg: [FILL] ms, max: [FILL] ms, calls: [FILL]
4. [Query] - avg: [FILL] ms, max: [FILL] ms, calls: [FILL]
5. [Query] - avg: [FILL] ms, max: [FILL] ms, calls: [FILL]

### Connection Pool Utilization

- Maximum active connections: [FILL IN] / 50
- Average active connections: [FILL IN]
- Connection wait time: [FILL IN] ms (average)

### Cache Hit Ratio

- Database cache hit ratio: [FILL IN]% (target: >95%)
- Analysis: [FILL IN]

### Table Statistics

- Total rows: [FILL IN]
- Inserts: [FILL IN]
- Updates: [FILL IN]
- Dead rows: [FILL IN]
- Table size: [FILL IN]

### Optimization Recommendations

1. [FILL IN]
2. [FILL IN]
3. [FILL IN]

---

## Scenario 5: E2E Latency

### Event Processing Latency

- p50: [FILL IN] ms
- p95: [FILL IN] ms
- p99: [FILL IN] ms

### Buffer Flush Performance

- Average flush interval: [FILL IN] ms (target: 1000ms)
- Average flush time: [FILL IN] ms
- Maximum flush time: [FILL IN] ms
- Average entries per flush: [FILL IN]

### E2E Latency Calculation

Event to API visibility:
- Minimum: [event processing p50] + [~0ms if just before flush] = [FILL IN] ms
- Maximum: [event processing p99] + [~1000ms if just after flush] = [FILL IN] ms
- Average: [event processing p50] + [~500ms average wait] = [FILL IN] ms

---

## Bottleneck Summary

### 1. [Primary Bottleneck Name]
   - **Impact:** [Describe impact]
   - **Evidence:** [Metrics that prove this]
   - **Recommendation:** [How to address]

### 2. [Secondary Bottleneck Name]
   - **Impact:** [Describe impact]
   - **Evidence:** [Metrics that prove this]
   - **Recommendation:** [How to address]

### 3. [Tertiary Bottleneck Name]
   - **Impact:** [Describe impact]
   - **Evidence:** [Metrics that prove this]
   - **Recommendation:** [How to address]

---

## Scaling Recommendations

### Vertical Scaling

**Configuration A: 2 CPU / 2 GB**
- Expected capacity: [FILL IN] RPS + [FILL IN] EPS
- Cost: 2x current
- Use case: [FILL IN]

**Configuration B: 4 CPU / 4 GB**
- Expected capacity: [FILL IN] RPS + [FILL IN] EPS
- Cost: 4x current
- Use case: [FILL IN]

### Horizontal Scaling

**Configuration C: 3 instances @ 1 CPU / 1 GB each**
- Expected capacity: [FILL IN] RPS + [FILL IN] EPS (3x single instance)
- Cost: 3x current
- Use case: High availability, load distribution
- Requires: Load balancer, shared database

---

## Conclusions

[Summary paragraph: What did you learn? What's the real-world capacity? What's the primary limitation?]

For production deployment with expected load >[FILL IN] RPS:
- Recommended: [Vertical or horizontal scaling approach]
- Database: [Configuration recommendations]
- Monitoring: [Key metrics to watch]

---

**Document Status:** Template - Fill in with test results
