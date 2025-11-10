# Technical Specification: Observability

**Version:** 1.0
**Date:** 2025-10-17
**Status:** M1 Scope

---

## Overview

This document defines observability standards for the Challenge Service, including logging, metrics, and monitoring.

---

## Logging

### Logging Framework

Use the Extend template's built-in logger (structured logging with key-value pairs).

### Standard Log Fields

**All log entries should include:**
```go
log.Info("Event description",
    "userId", userId,
    "namespace", namespace,
    // Additional context fields...
)
```

### Log Levels

| Level | Usage |
|-------|-------|
| **Debug** | Detailed debugging information (disabled in production) |
| **Info** | Normal operational messages (event processed, API called) |
| **Warn** | Warning conditions (deprecated usage, retry attempts) |
| **Error** | Error conditions (failed DB query, reward grant failed) |

### Event Handler Logging

**Event Processing:**
```go
log.Info("Event processed",
    "userId", userId,
    "eventType", "statItemUpdated",
    "statCode", statCode,
    "value", value,
    "goalsUpdated", len(goals),
    "duration", elapsed.Milliseconds(),
)

log.Error("Failed to process event",
    "userId", userId,
    "eventType", eventType,
    "error", err,
)
```

**Buffer Flush:**
```go
log.Info("Buffer flushed",
    "absoluteGoalsCount", len(absoluteBuffer),
    "incrementGoalsCount", len(incrementBuffer),
    "duration", elapsed.Milliseconds(),
)

log.Error("Failed to flush buffer",
    "bufferSize", len(buffer),
    "error", err,
    "willRetry", true,
)
```

### API Service Logging

**Request Handling:**
```go
log.Info("API request",
    "method", "GET",
    "path", "/v1/challenges",
    "userId", userId,
    "duration", elapsed.Milliseconds(),
)

log.Error("API error",
    "method", "POST",
    "path", "/v1/challenges/{id}/goals/{id}/claim",
    "userId", userId,
    "error", err,
    "statusCode", 502,
)
```

**Reward Grants:**
```go
log.Info("Reward granted",
    "userId", userId,
    "goalId", goalId,
    "rewardType", rewardType,
    "rewardId", rewardId,
    "quantity", quantity,
    "attempt", attempt,
)

log.Error("Failed to grant reward",
    "userId", userId,
    "goalId", goalId,
    "rewardType", rewardType,
    "rewardId", rewardId,
    "attempt", attempt,
    "error", err,
)
```

### Configuration Loading

**Startup:**
```go
log.Info("Config loaded",
    "challengeCount", len(config.Challenges),
    "totalGoals", totalGoals,
    "configPath", configPath,
)

log.Error("Config validation failed",
    "error", err,
    "configPath", configPath,
)
```

---

## Metrics

### Metrics Framework

Use Prometheus metrics via the template's built-in metrics emitter (port 8080).

### M1 Metrics (Minimal Set)

**Decision:** Keep metrics minimal in M1 to reduce complexity. Add more metrics in M2+ as needed.

#### Event Processing Metrics

```go
// Event processing duration (histogram)
challengeEventProcessingDuration := prometheus.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:    "challenge_event_processing_duration_seconds",
        Help:    "Duration of event processing in seconds",
        Buckets: prometheus.DefBuckets, // 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
    },
    []string{"event_type", "status"}, // event_type: "statItemUpdated" | "userLoggedIn", status: "success" | "error"
)

// Usage:
start := time.Now()
// ... process event ...
challengeEventProcessingDuration.WithLabelValues(
    "statItemUpdated",
    "success",
).Observe(time.Since(start).Seconds())
```

#### Buffer Flush Metrics

```go
// Buffer flush duration (histogram)
challengeBufferFlushDuration := prometheus.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:    "challenge_buffer_flush_duration_seconds",
        Help:    "Duration of buffer flush in seconds",
        Buckets: []float64{0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.5, 1}, // More granular for DB operations
    },
    []string{"buffer_type", "status"}, // buffer_type: "absolute" | "increment", status: "success" | "error"
)

// Buffer size at flush time (gauge)
challengeBufferSize := prometheus.NewGaugeVec(
    prometheus.GaugeOpts{
        Name: "challenge_buffer_size",
        Help: "Number of items in buffer at flush time",
    },
    []string{"buffer_type"}, // buffer_type: "absolute" | "increment"
)

// Usage:
challengeBufferSize.WithLabelValues("absolute").Set(float64(len(absoluteBuffer)))
start := time.Now()
// ... flush buffer ...
challengeBufferFlushDuration.WithLabelValues(
    "absolute",
    "success",
).Observe(time.Since(start).Seconds())
```

#### API Metrics

```go
// API request duration (histogram)
challengeAPIRequestDuration := prometheus.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:    "challenge_api_request_duration_seconds",
        Help:    "Duration of API requests in seconds",
        Buckets: prometheus.DefBuckets,
    },
    []string{"method", "path", "status_code"},
)

// Usage:
start := time.Now()
// ... handle request ...
challengeAPIRequestDuration.WithLabelValues(
    "GET",
    "/v1/challenges",
    "200",
).Observe(time.Since(start).Seconds())
```

### Deferred to M2+

**More detailed metrics (not in M1):**
- Goal completion counters (per challenge, per goal)
- Reward claim counters (per reward type)
- Cache hit/miss ratios
- Database connection pool usage
- Per-user activity metrics

**Rationale:** M1 focuses on functional correctness. Advanced metrics add complexity and overhead. Expand in M2+ based on real usage patterns.

### Metrics Endpoint

**Prometheus scrape endpoint:**
```
GET http://localhost:8080/metrics
```

**No authentication required** (metrics server runs on separate port for Prometheus scraping).

---

## Monitoring

### Health Checks

**Liveness Probe:**
```
GET /healthz
```

**Response:**
```json
{
  "status": "healthy"
}
```

**Usage:** Kubernetes liveness probe checks if service is running.

**Note:** Extend environment only supports `/healthz`. No `/readyz` endpoint.

### Performance Targets

| Metric | Target (p95) | Alerting Threshold |
|--------|-------------|-------------------|
| API Response Time | < 200ms | > 500ms |
| Event Processing Time | < 50ms | > 200ms |
| Event Processing Lag | < 5s | > 30s |
| Database Query Time | < 50ms | > 200ms |
| Cache Lookup Time | < 1ms | N/A (in-memory) |
| Buffer Flush Time | < 20ms (1000 rows) | > 100ms |

### Alerting Rules (Prometheus)

**Example alerts (deploy in M2+):**

```yaml
groups:
  - name: challenge_service
    rules:
      - alert: HighEventProcessingLatency
        expr: histogram_quantile(0.95, challenge_event_processing_duration_seconds) > 0.2
        for: 5m
        annotations:
          summary: "Event processing p95 latency > 200ms"

      - alert: HighBufferFlushLatency
        expr: histogram_quantile(0.95, challenge_buffer_flush_duration_seconds) > 0.1
        for: 5m
        annotations:
          summary: "Buffer flush p95 latency > 100ms"

      - alert: HighAPILatency
        expr: histogram_quantile(0.95, challenge_api_request_duration_seconds{path="/v1/challenges"}) > 0.5
        for: 5m
        annotations:
          summary: "API p95 latency > 500ms"
```

---

## Tracing (Future - M3+)

**Not implemented in M1:**
- Distributed tracing (OpenTelemetry)
- Request correlation IDs
- Span propagation

**Rationale:** M1 focuses on core functionality. Add tracing in M3+ for debugging complex flows.

---

## Log Aggregation

### Log Format

All logs output to **stdout** in JSON format (Extend platform captures and forwards to log aggregation service).

**Example log entry:**
```json
{
  "level": "info",
  "timestamp": "2025-10-17T10:30:00Z",
  "message": "Event processed",
  "userId": "user123",
  "eventType": "statItemUpdated",
  "statCode": "kills",
  "value": 15,
  "goalsUpdated": 2,
  "duration": 12
}
```

### Log Retention

**Determined by AccelByte Extend platform configuration** (typically 7-30 days).

---

## Dashboard (Future - M2+)

**Grafana dashboard with:**
- Event processing rate (events/sec)
- Buffer flush performance
- API request latency (p50, p95, p99)
- Error rates
- Database query latency

**Not implemented in M1** - focus on functional correctness first.

---

## References

- **Prometheus Best Practices:** https://prometheus.io/docs/practices/naming/
- **Structured Logging:** https://github.com/sirupsen/logrus (or template's logger)
- **AccelByte Extend Metrics:** Template's built-in metrics emitter (port 8080)

---

**Document Status:** M1 Scope Complete

**Related Decisions:**
- BRAINSTORM.md Decision 10: Analytics & Metrics
- BRAINSTORM.md Decision 47: Logging Structure
- BRAINSTORM.md Decision 48: Metrics Labels
