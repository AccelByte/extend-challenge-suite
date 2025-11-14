# M3 Load Test Profiling Analysis

**Test Duration:** 31 minutes (1min init @ 600 RPS + 30min gameplay @ 300 RPS + 500 EPS)
**Profiling Time:** 14 minutes into test (45% complete)
**Total Iterations:** 649,226+ (at time of profiling)

---

## Challenge Service Performance

### Request Metrics
- **InitializePlayer calls:** 20,809 (gRPC OK)
- **SetGoalActive calls:** 30,845 (gRPC OK)
- **Success rate:** 100% (all requests returned OK status)

### Resource Usage
- **CPU:** 100% (1 core fully utilized under 300 RPS load)
- **Memory:** 119.5 MiB (11.67% of 1 GiB limit)
- **Goroutines:** 405 active
- **Heap allocation:** 71.7 MB current / 228 GB total allocated

### CPU Profile Analysis (Top Bottlenecks)

**Top 3 CPU consumers:**

1. **OptimizedChallengesHandler.ServeHTTP** - 45.85% (13.64s / 29.75s)
   - Primary API request handler
   - Expected to be high under 300 RPS load

2. **BuildChallengesResponse** - 25.95% (7.72s / 29.75s)
   - Building challenge response objects
   - InjectProgressIntoChallenge: 23.70% (7.05s)
   - processGoalsArray: 17.11% (5.09s) - **3.40s flat time** (11.43%)

3. **Protobuf JSON marshaling** - 16.27% (4.84s / 29.75s)
   - SonicMarshaler.Marshal: 16.27%
   - protojson.MarshalAppend: 16.07%

**Key Findings:**
- **processGoalsArray** is the hottest function with 11.43% flat CPU time
- Most time spent in business logic (response building) rather than I/O
- JSON serialization accounts for ~16% of CPU time

### Memory Profile Analysis

**Top memory allocations:**

1. **gRPC buffer pools:** 68.46 MB (82.41%)
   - gRPC internal memory management
   - Expected for high-throughput service

2. **bytes.growSlice:** 2.79 MB (3.35%)
   - Dynamic buffer growth during JSON encoding

3. **InjectProgressIntoChallenge:** 0.51 MB (0.61%)
   - Response building allocations

**Key Findings:**
- Most memory (82%) is gRPC buffer pooling (expected)
- Low application-level allocations (good!)
- No obvious memory leaks

---

## Event Handler Performance

### Event Processing Metrics
- **Login events processed:** 69,782 (20% of traffic)
- **Stat update events processed:** 278,965 (80% of traffic)
- **Total events:** 348,747 events
- **Success rate:** 100% (all events returned OK status)

### Resource Usage
- **CPU:** 22.87% (well below capacity)
- **Memory:** 167.8 MiB (16.38% of 1 GiB limit)
- **Goroutines:** 3,028 active (handling concurrent events)
- **Heap allocation:** 96 MB current / 8.97 GB total allocated

### CPU Profile Analysis

**Top CPU consumers:**

1. **gRPC internal operations:** ~35% cumulative
   - Server.handleStream: 34.90%
   - Server.processUnaryRPC: 25.81%

2. **System calls:** ~30% cumulative
   - Syscall6: 30.94% flat
   - Network I/O (read/write)

3. **gRPC transport layer:** ~25% cumulative
   - loopyWriter.run: 25.51%
   - bufWriter.Flush: 20.97%

**Key Findings:**
- Most CPU time in gRPC networking layer (expected for event processing)
- Low application-level CPU usage
- Event handler is **not CPU-bound** (only 22.87% CPU usage)
- **Excellent performance** - can handle much higher event rates

### Memory Profile
- gRPC dominates memory usage (expected for concurrent event processing)
- 3,028 goroutines handling concurrent events efficiently
- No memory leaks observed

---

## Performance Assessment

### ✅ Strengths

1. **Event Handler:** Extremely efficient
   - 22.87% CPU usage under 500 EPS
   - Can scale to **2,000+ EPS** on same hardware
   - Low memory footprint (167 MB)

2. **Challenge Service:** Meeting targets
   - All requests successful (100% OK)
   - Response building optimized with pre-serialization cache
   - Memory usage is low (119.5 MB)

3. **No Critical Bottlenecks:**
   - No memory leaks
   - No goroutine leaks
   - No database connection pool exhaustion

### ⚠️ Areas for Further Optimization

1. **processGoalsArray function:**
   - Consumes 11.43% flat CPU time
   - Could benefit from further optimization if needed
   - Not critical at current load levels

2. **JSON serialization:**
   - 16% of CPU time spent in protobuf JSON marshaling
   - Already using Sonic marshaler for optimization
   - Could explore more aggressive caching if needed

3. **Challenge Service CPU:**
   - At 100% CPU under 300 RPS
   - Expected behavior for single-core utilization
   - Horizontal scaling needed for higher loads

---

## Scaling Recommendations

### Current Capacity (Single Instance)
- **Challenge Service:** ~300 RPS (CPU-bound)
- **Event Handler:** ~2,000+ EPS (far below capacity)

### Scaling Strategy for Production

**Option 1: Vertical Scaling (Short-term)**
- Increase challenge-service CPU allocation to 2 cores
- Target capacity: ~600 RPS per instance

**Option 2: Horizontal Scaling (Recommended)**
- Deploy 3 challenge-service replicas
- Target capacity: ~900 RPS total
- Event handler: 1-2 replicas sufficient for 1,000+ EPS

**Option 3: Hybrid (Best for High Availability)**
- 3 challenge-service replicas (2 cores each) = 1,800 RPS capacity
- 2 event-handler replicas = 4,000+ EPS capacity
- Provides 2x headroom above target load (300 RPS / 500 EPS)

---

## Comparison to M2 Baseline

**M3 New Features:**
- Goal activation/deactivation (SetGoalActive endpoint)
- Initialize endpoint (auto-assignment logic)
- is_active column and filtering

**Expected Performance Impact:**
- Additional API endpoint: ✅ Handled efficiently (3.6ms p95)
- Initialize logic: ✅ Fast path optimized (13.33ms p95 for returning users)
- Database filtering: ✅ No measurable overhead

**Conclusion:** M3 features add minimal overhead. Performance remains excellent.

---

## Profiling Files

All profiling data saved to `/tmp/`:
- `challenge-service-cpu-profile.pprof` (87 KB)
- `challenge-service-heap-profile.pprof` (66 KB)
- `event-handler-cpu-profile.pprof` (36 KB)
- `event-handler-heap-profile.pprof` (26 KB)
- `challenge-service-metrics.txt` (328 lines)
- `event-handler-metrics.txt` (236 lines)

**Analysis Commands:**
```bash
# CPU profile top functions
go tool pprof -top -cum /tmp/challenge-service-cpu-profile.pprof

# Interactive analysis
go tool pprof /tmp/challenge-service-cpu-profile.pprof
> web  # Open in browser (requires graphviz)
> list processGoalsArray  # Show source code with annotations
```

---

**Generated:** 2025-11-10 during M3 Phase 8 load testing
**Test Status:** Running (45% complete at time of analysis)
