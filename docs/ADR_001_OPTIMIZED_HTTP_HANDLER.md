# ADR 001: Optimized HTTP Handler for GET /v1/challenges

**Status:** Accepted
**Date:** 2025-11-07
**Decision Makers:** Architecture Team

## Context

The gRPC-Gateway automatically generates HTTP endpoints from protobuf definitions. However, for high-traffic endpoints, the protobuf → JSON conversion overhead can become a bottleneck.

Performance measurements showed:
- Standard gRPC-Gateway: ~200 RPS @ 101% CPU
- Optimized HTTP handler: ~400 RPS @ 50% CPU
- **Performance gain: 2x throughput, 50% CPU reduction**

## Decision

**We bypass the gRPC-Gateway for `GET /v1/challenges` and use a custom optimized HTTP handler.**

### Implementation Details

**File:** `extend-challenge-service/pkg/handler/optimized_challenges_handler.go`

**Route Registration:** `main.go:303-315`
```go
// Register optimized challenges endpoint BEFORE the catch-all gRPC-Gateway handler
// This endpoint uses pre-serialized challenge data for ~40% CPU reduction
// Path must match the protobuf definition: GET /v1/challenges
optimizedPath := basePath + "/v1/challenges"
mux.Handle(optimizedPath, optimizedChallengesHandler)
```

**Key Optimization:** Pre-serialized challenge cache (`SerializedChallengeCache`)
- Static challenge data is serialized once at startup
- User progress is injected at request time
- No protobuf → JSON conversion overhead

## Consequences

### Positive
- **2x better throughput** (200 → 400 RPS)
- **50% CPU reduction** (101% → 50% CPU @ same load)
- Lower memory allocations (2.96 MB → 0.89 MB per request)

### Negative
- **Feature parity must be maintained manually**
- Changes to gRPC handler must be replicated to HTTP handler
- Additional testing overhead (both handlers must be tested)

## Compliance Checklist

**⚠️ CRITICAL: When modifying GET /v1/challenges functionality:**

1. ✅ Update gRPC handler (`pkg/server/challenge_service_server.go:GetUserChallenges`)
2. ✅ Update HTTP handler (`pkg/handler/optimized_challenges_handler.go:ServeHTTP`)
3. ✅ Update protobuf definition if API contract changes
4. ✅ Add tests for BOTH handlers
5. ✅ Update this ADR if behavior changes

## Related Files

**Primary Implementation:**
- `pkg/handler/optimized_challenges_handler.go` - HTTP handler
- `pkg/server/challenge_service_server.go` - gRPC handler (GetUserChallenges method)
- `pkg/cache/serialized_challenge_cache.go` - Pre-serialization cache
- `pkg/response/json_injector.go` - User progress injection

**Configuration:**
- `main.go:294-315` - Handler registration and routing

**Tests:**
- `pkg/handler/optimized_challenges_handler_test.go` - HTTP handler tests
- `pkg/server/challenge_service_server_test.go` - gRPC handler tests

**Documentation:**
- `docs/OPTIMIZATION.md` - Performance analysis
- `docs/TECH_SPEC_API.md` - API specification

## Examples of Feature Parity

### M3 Phase 4: active_only Parameter

**Protobuf Definition:**
```protobuf
message GetChallengesRequest {
  bool active_only = 1;
}
```

**gRPC Handler:**
```go
activeOnly := req.GetActiveOnly()
challenges, err := service.GetUserChallengesWithProgress(ctx, userID, namespace, h.goalCache, h.repo, activeOnly)
```

**HTTP Handler:**
```go
activeOnly := r.URL.Query().Get("active_only") == "true"
allProgress, err := h.repo.GetUserProgress(ctx, userID, activeOnly)
```

Both handlers call the same repository method with the same parameter.

## Future Considerations

### When to Add More Optimized Handlers

Consider bypassing gRPC-Gateway for endpoints that:
1. Have >1000 RPS traffic
2. Return mostly static data
3. Show >50% CPU usage in profiling
4. Have simple request/response structure

### When to Remove Optimization

If any of these become true:
1. Feature parity maintenance becomes too expensive
2. Performance gain drops below 30%
3. gRPC-Gateway performance improves significantly

## Monitoring

**Performance Metrics to Track:**
- Endpoint latency (p50, p95, p99)
- CPU usage per request
- Memory allocations per request
- Throughput (RPS)

**Alert if:**
- HTTP handler latency diverges from gRPC handler by >20%
- Test coverage for either handler drops below 80%
- Feature parity is broken (detected via integration tests)

## References

- Performance benchmarking: `docs/OPTIMIZATION.md`
- Original implementation: PR #XXX (if using PR workflow)
- Related ADRs: None yet
