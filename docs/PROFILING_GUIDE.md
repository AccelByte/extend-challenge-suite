# Profiling Guide: Using pprof

**Version:** 1.0
**Date:** 2025-10-24
**Purpose:** Guide for profiling the Challenge Service using Go's pprof

---

## Overview

Both `extend-challenge-service` and `extend-challenge-event-handler` have pprof profiling endpoints enabled on port **8080** (the same port as Prometheus metrics).

**Available Endpoints:**
- Backend Service: `http://localhost:8080/debug/pprof/`
- Event Handler: `http://localhost:8080/debug/pprof/`

---

## Quick Start

### 1. Start the Services

```bash
# Terminal 1: Start backend service
cd extend-challenge-service
make run

# Terminal 2: Start event handler
cd extend-challenge-event-handler
make run
```

### 2. Run Load Test

```bash
# Your load test scenario here
# Example using k6, wrk, or Apache Bench
```

### 3. Capture Profiles

While the load test is running, capture profiles in a separate terminal.

---

## Profile Types

### CPU Profile (30 seconds)

Captures where CPU time is being spent:

```bash
# Backend service
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30

# Event handler
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30
```

**What it shows:**
- Which functions consume the most CPU time
- Hot paths in your code
- JSON encoding/decoding overhead
- Database query overhead

**When to use:** Finding performance bottlenecks, slow functions

### Heap Profile (Memory)

Captures current memory allocations:

```bash
# Backend service
go tool pprof http://localhost:8080/debug/pprof/heap

# Event handler
go tool pprof http://localhost:8080/debug/pprof/heap
```

**What it shows:**
- Memory allocation patterns
- Which functions allocate the most memory
- Memory leaks (if present)

**When to use:** High memory usage, investigating memory leaks

### Goroutine Profile

Shows all running goroutines:

```bash
go tool pprof http://localhost:8080/debug/pprof/goroutine
```

**What it shows:**
- Number of goroutines
- Where goroutines are blocked
- Potential goroutine leaks

**When to use:** Debugging concurrency issues, goroutine leaks

### Allocs Profile

Captures all memory allocations (past and present):

```bash
go tool pprof http://localhost:8080/debug/pprof/allocs
```

**What it shows:**
- Total allocations over time
- Allocation frequency
- GC pressure

**When to use:** Optimizing memory allocations, reducing GC overhead

### Block Profile

Shows where goroutines block on synchronization:

```bash
go tool pprof http://localhost:8080/debug/pprof/block
```

**What it shows:**
- Contention on mutexes
- Channel blocking
- Synchronization bottlenecks

**When to use:** Debugging slow concurrent operations

### Mutex Profile

Shows mutex contention:

```bash
go tool pprof http://localhost:8080/debug/pprof/mutex
```

**What it shows:**
- Lock contention
- Which mutexes are most contested
- Lock holder time

**When to use:** Optimizing concurrent code, reducing lock contention

---

## Interactive Analysis

### pprof Web UI

Start interactive web UI (recommended):

```bash
# Capture CPU profile
go tool pprof -http=:9090 http://localhost:8080/debug/pprof/profile?seconds=30
```

This opens a browser at `http://localhost:9090` with:
- **Graph view**: Visual call graph
- **Flame graph**: Interactive flame graph (best for finding bottlenecks)
- **Top**: Functions sorted by CPU/memory usage
- **Source**: Annotated source code

### pprof Interactive CLI

```bash
# Start interactive session
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30

# Common commands:
(pprof) top           # Show top 10 functions
(pprof) top 20        # Show top 20 functions
(pprof) list funcName # Show annotated source for function
(pprof) web           # Generate call graph (requires graphviz)
(pprof) pdf           # Generate PDF call graph
(pprof) help          # Show all commands
```

---

## Profiling Workflow for JSON Optimization

### Step 1: Baseline CPU Profile (During Load Test)

```bash
# Capture 30-second CPU profile during load test
go tool pprof -http=:9090 http://localhost:8080/debug/pprof/profile?seconds=30
```

### Step 2: Analyze Flame Graph

1. Open browser at `http://localhost:9090`
2. Click **VIEW → Flame Graph**
3. Look for:
   - `encoding/json.Marshal` or `json.Unmarshal`
   - `runtime.mallocgc` (memory allocations)
   - Database operations (`database/sql`)

### Step 3: Check JSON Usage

```bash
# In pprof CLI, search for JSON functions
(pprof) top -cum
(pprof) list encoding/json
```

### Step 4: Compare Before/After

```bash
# Save baseline profile
go tool pprof -proto http://localhost:8080/debug/pprof/profile?seconds=30 > baseline.pb.gz

# After optimization, capture new profile
go tool pprof -proto http://localhost:8080/debug/pprof/profile?seconds=30 > optimized.pb.gz

# Compare
go tool pprof -http=:9090 -diff_base=baseline.pb.gz optimized.pb.gz
```

---

## Specific Checks for JSON Performance

### 1. Check JSON Marshal/Unmarshal Time

```bash
# Capture CPU profile
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30

# In interactive mode:
(pprof) top -cum
(pprof) list encoding/json.Marshal
(pprof) list encoding/json.Unmarshal
```

**What to look for:**
- If `encoding/json.*` functions appear in top 10 → JSON is a bottleneck
- If they're < 5% of CPU time → JSON is not the problem

### 2. Check Memory Allocations from JSON

```bash
# Capture allocs profile during load test
go tool pprof http://localhost:8080/debug/pprof/allocs

# In interactive mode:
(pprof) top -cum
(pprof) list json
```

**What to look for:**
- High allocation counts in JSON functions
- Large allocation sizes

### 3. Check gRPC Gateway JSON Overhead

```bash
# Capture CPU profile
go tool pprof -http=:9090 http://localhost:8080/debug/pprof/profile?seconds=30

# Look for:
# - grpc-gateway/runtime/marshal*
# - google.golang.org/protobuf/encoding/protojson
```

---

## Continuous Profiling (Optional)

### Save Profiles Periodically

```bash
#!/bin/bash
# save-profiles.sh

SERVICE="backend"  # or "event-handler"
PORT=8080
OUTPUT_DIR="./profiles/$SERVICE"
mkdir -p "$OUTPUT_DIR"

# Capture CPU profile every 5 minutes
while true; do
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  echo "Capturing CPU profile at $TIMESTAMP..."

  curl -s "http://localhost:$PORT/debug/pprof/profile?seconds=30" \
    > "$OUTPUT_DIR/cpu_$TIMESTAMP.pb.gz"

  curl -s "http://localhost:$PORT/debug/pprof/heap" \
    > "$OUTPUT_DIR/heap_$TIMESTAMP.pb.gz"

  sleep 300  # Wait 5 minutes
done
```

### Analyze Historical Profiles

```bash
# Compare profiles over time
go tool pprof -http=:9090 -diff_base=profiles/backend/cpu_20251024_100000.pb.gz \
  profiles/backend/cpu_20251024_110000.pb.gz
```

---

## Best Practices

### DO:
- ✅ **Profile under realistic load** - Use production-like traffic patterns
- ✅ **Capture longer profiles** - 30-60 seconds for CPU profiles
- ✅ **Profile both services** - Backend and event handler separately
- ✅ **Save baseline profiles** - Before making optimizations
- ✅ **Use flame graphs** - Easiest way to spot bottlenecks

### DON'T:
- ❌ **Don't profile in production** - Use staging/load test environment
- ❌ **Don't profile idle services** - Must be under load
- ❌ **Don't optimize without profiling** - Measure first, optimize second
- ❌ **Don't trust short profiles** - Need statistically significant samples

---

## Interpreting Results for JSON Optimization

### Scenario 1: JSON is a bottleneck

```
(pprof) top
Total: 10000 samples
    1500  15.0%  encoding/json.Marshal
    1200  12.0%  encoding/json.Unmarshal
     800   8.0%  runtime.mallocgc
```

**Action:** JSON optimization (sonic/go-json) would help significantly

### Scenario 2: JSON is not the problem

```
(pprof) top
Total: 10000 samples
    3000  30.0%  database/sql.(*DB).QueryContext
    2000  20.0%  github.com/lib/pq.(*conn).Query
     500   5.0%  encoding/json.Marshal
```

**Action:** Focus on database optimization, not JSON

### Scenario 3: gRPC Gateway overhead

```
(pprof) top -cum
Total: 10000 samples
    2000  20.0%  grpc-gateway/runtime.ForwardResponseMessage
    1500  15.0%  google.golang.org/protobuf/encoding/protojson.Marshal
```

**Action:** Custom JSON marshaler for gRPC Gateway would help

---

## Example: Full Profiling Session

```bash
# 1. Start services
make run

# 2. Start load test (in another terminal)
k6 run loadtest.js

# 3. Capture CPU profile (in another terminal)
go tool pprof -http=:9090 http://localhost:8080/debug/pprof/profile?seconds=30

# 4. In browser (http://localhost:9090):
#    - Click VIEW → Flame Graph
#    - Hover over boxes to see function names
#    - Click to zoom in
#    - Look for json.Marshal/Unmarshal

# 5. Save profile for later
curl http://localhost:8080/debug/pprof/profile?seconds=30 > cpu-baseline.pb.gz

# 6. After making changes, compare
go tool pprof -http=:9090 -diff_base=cpu-baseline.pb.gz \
  http://localhost:8080/debug/pprof/profile?seconds=30
```

---

## Troubleshooting

### pprof endpoint not accessible

```bash
# Check if service is running
curl http://localhost:8080/debug/pprof/

# Check if port 8080 is open
netstat -an | grep 8080

# Check service logs
grep "pprof" service.log
```

### No data in profile

- Service must be under load when capturing
- Wait for profile duration to complete (don't interrupt)
- Check if load test is actually hitting the service

### Graph/PDF generation fails

```bash
# Install graphviz
sudo apt-get install graphviz  # Ubuntu/Debian
brew install graphviz          # macOS
```

---

## Next Steps

After capturing profiles:

1. **Identify bottlenecks** - Use flame graphs to find hot paths
2. **Quantify impact** - Calculate % of time spent in JSON encoding
3. **Decide on optimization** - If JSON > 10% of CPU time, consider sonic/go-json
4. **Implement changes** - Start with small, measurable improvements
5. **Re-profile** - Verify improvements with new profiles
6. **Compare** - Use `-diff_base` to show before/after

---

## References

- [pprof Documentation](https://github.com/google/pprof/blob/main/doc/README.md)
- [Profiling Go Programs](https://go.dev/blog/pprof)
- [Flame Graphs](http://www.brendangregg.com/flamegraphs.html)
