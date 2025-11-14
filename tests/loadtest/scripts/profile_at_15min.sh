#!/bin/bash

# Run pprof profiling at 15-minute mark
# This script should be started immediately after the load test begins

echo "=== Phase 10: pprof Profiling at 15-Minute Mark ==="
echo "Start time: $(date)"
echo ""

# Calculate 15-minute mark (900 seconds)
START_TIME=$(date +%s)
PROFILE_TIME=$((START_TIME + 900))

echo "Will profile at: $(date -d @$PROFILE_TIME '+%Y-%m-%d %H:%M:%S')"
echo ""

RESULTS_DIR="tests/loadtest/results/m3_phase10_timezone_fix_20251111"

# Wait until 15-minute mark
CURRENT_TIME=$(date +%s)
WAIT_TIME=$((PROFILE_TIME - CURRENT_TIME))

if [ $WAIT_TIME -gt 0 ]; then
    echo "Waiting ${WAIT_TIME} seconds until 15-minute mark..."
    sleep $WAIT_TIME
fi

echo ""
echo "=== PROFILING NOW (15-Minute Mark) ==="
echo "Time: $(date)"
echo ""

# 1. pprof CPU Profile (30 seconds sample)
echo "--- Go pprof CPU Profile (30s sample) ---"
echo "  Challenge Service: Capturing CPU profile..."
curl -s "http://localhost:8080/debug/pprof/profile?seconds=30" -o "${RESULTS_DIR}/service_cpu_15min.pprof" &
SERVICE_CPU_PID=$!

echo "  Event Handler: Capturing CPU profile..."
curl -s "http://localhost:8081/debug/pprof/profile?seconds=30" -o "${RESULTS_DIR}/handler_cpu_15min.pprof" &
HANDLER_CPU_PID=$!

# Wait for CPU profiling to complete
echo "  Waiting for CPU profiles to complete (30s)..."
wait $SERVICE_CPU_PID
wait $HANDLER_CPU_PID
echo "  ✓ CPU profiles saved"
echo ""

# 2. pprof Heap Profile (memory allocation)
echo "--- Go pprof Heap Profile ---"
echo "  Challenge Service: Capturing heap profile..."
curl -s "http://localhost:8080/debug/pprof/heap" -o "${RESULTS_DIR}/service_heap_15min.pprof"

echo "  Event Handler: Capturing heap profile..."
curl -s "http://localhost:8081/debug/pprof/heap" -o "${RESULTS_DIR}/handler_heap_15min.pprof"
echo "  ✓ Heap profiles saved"
echo ""

# 3. pprof Goroutine Profile
echo "--- Go pprof Goroutine Profile ---"
echo "  Challenge Service: Capturing goroutine profile..."
curl -s "http://localhost:8080/debug/pprof/goroutine" -o "${RESULTS_DIR}/service_goroutine_15min.txt"

echo "  Event Handler: Capturing goroutine profile..."
curl -s "http://localhost:8081/debug/pprof/goroutine" -o "${RESULTS_DIR}/handler_goroutine_15min.txt"
echo "  ✓ Goroutine profiles saved"
echo ""

# 4. pprof Mutex Profile (contention)
echo "--- Go pprof Mutex Profile ---"
echo "  Challenge Service: Capturing mutex profile..."
curl -s "http://localhost:8080/debug/pprof/mutex" -o "${RESULTS_DIR}/service_mutex_15min.pprof"

echo "  Event Handler: Capturing mutex profile..."
curl -s "http://localhost:8081/debug/pprof/mutex" -o "${RESULTS_DIR}/handler_mutex_15min.pprof"
echo "  ✓ Mutex profiles saved"
echo ""

# 5. Prometheus Metrics Snapshot
echo "--- Prometheus Metrics Snapshot ---"
echo "  Challenge Service:"
curl -s http://localhost:8080/metrics | grep -E "^(go_goroutines|process_cpu_seconds_total|process_resident_memory_bytes|http_requests_total)" | head -20
echo ""

echo "  Event Handler:"
curl -s http://localhost:8081/metrics | grep -E "^(go_goroutines|process_cpu_seconds_total|process_resident_memory_bytes)" | head -20
echo ""

# 6. PostgreSQL Performance Stats
echo "--- PostgreSQL Performance Stats ---"

echo "  Connection Stats:"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "
    SELECT
        count(*) as total_connections,
        count(*) FILTER (WHERE state = 'active') as active,
        count(*) FILTER (WHERE state = 'idle') as idle,
        count(*) FILTER (WHERE state = 'idle in transaction') as idle_in_transaction
    FROM pg_stat_activity
    WHERE datname = 'challenge_db';
"
echo ""

echo "  Query Performance (slowest queries):"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "
    SELECT
        calls,
        ROUND(mean_exec_time::numeric, 2) as avg_ms,
        ROUND(total_exec_time::numeric, 2) as total_ms,
        query
    FROM pg_stat_statements
    WHERE query NOT LIKE '%pg_stat%'
    ORDER BY mean_exec_time DESC
    LIMIT 5;
" 2>/dev/null || echo "  (pg_stat_statements not available)"
echo ""

echo "  Table Stats (user_goal_progress):"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "
    SELECT
        seq_scan as sequential_scans,
        seq_tup_read as rows_seq_read,
        idx_scan as index_scans,
        idx_tup_fetch as rows_idx_fetched,
        n_tup_ins as inserts,
        n_tup_upd as updates,
        n_tup_del as deletes,
        n_live_tup as live_rows
    FROM pg_stat_user_tables
    WHERE relname = 'user_goal_progress';
"
echo ""

echo "  Database Size:"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "
    SELECT
        pg_size_pretty(pg_database_size('challenge_db')) as db_size;
"
echo ""

# 7. Docker Container Stats
echo "--- Docker Container Stats (15-min mark) ---"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" challenge-service challenge-event-handler challenge-postgres challenge-redis
echo ""

# 8. Recent Initialize Latencies
echo "--- Recent Initialize Latencies (last 10) ---"
docker logs challenge-service --tail=100 2>&1 | grep "HTTP request.*initialize" | tail -10
echo ""

echo "✅ Profiling complete!"
echo ""
echo "📊 Profile files saved to: ${RESULTS_DIR}/"
echo "   - service_cpu_15min.pprof (CPU profile)"
echo "   - service_heap_15min.pprof (memory allocation)"
echo "   - service_goroutine_15min.txt (goroutine stacks)"
echo "   - service_mutex_15min.pprof (lock contention)"
echo "   - handler_cpu_15min.pprof (CPU profile)"
echo "   - handler_heap_15min.pprof (memory allocation)"
echo "   - handler_goroutine_15min.txt (goroutine stacks)"
echo "   - handler_mutex_15min.pprof (lock contention)"
echo ""
echo "📖 To analyze pprof files:"
echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/service_cpu_15min.pprof"
echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/service_heap_15min.pprof"
echo "   go tool pprof ${RESULTS_DIR}/service_cpu_15min.pprof  # Text mode"
echo ""
