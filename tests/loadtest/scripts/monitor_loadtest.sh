#!/bin/bash

# Reusable Load Test Monitor
# Profiles CPU/Memory at 15-minute mark
# Provides real-time progress updates
#
# Usage: ./monitor_loadtest.sh <results_dir>
# Example: ./monitor_loadtest.sh tests/loadtest/results/m3_phase16_test_20251113_123456
#
# Note: The results_dir should be the same directory where k6 is writing its output

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Validate arguments
if [ $# -ne 1 ]; then
    echo "ERROR: Wrong number of arguments"
    echo "Usage: $0 <results_dir>"
    echo "Example: $0 tests/loadtest/results/m3_phase16_test_20251113_123456"
    exit 1
fi

RESULTS_DIR="$1"

# Validate results directory exists
if [ ! -d "${RESULTS_DIR}" ]; then
    echo "ERROR: Results directory does not exist: ${RESULTS_DIR}"
    exit 1
fi

# Convert to absolute path to avoid issues
RESULTS_DIR=$(cd "${RESULTS_DIR}" && pwd)

echo "=== Load Test Monitor ==="
echo "Start time: $(date)"
echo "Results directory: ${RESULTS_DIR}"
echo ""

# Calculate target times
START_TIME=$(date +%s)
PROFILE_TIME=$((START_TIME + 900))  # 15 minutes = 900 seconds
EXPECTED_END=$((START_TIME + 1860)) # 31 minutes = 1860 seconds

echo "Timeline:"
echo "  - Profile at: $(date -d @$PROFILE_TIME '+%Y-%m-%d %H:%M:%S') (15 min mark)"
echo "  - Expected end: $(date -d @$EXPECTED_END '+%Y-%m-%d %H:%M:%S') (31 min total)"
echo ""

# Function to check if k6 is still running
check_k6_running() {
    pgrep -f "k6 run.*scenario3_combined" > /dev/null
    return $?
}

# Wait for 15 minutes or until test completes
echo "Waiting for 15-minute mark to profile services..."
while [ $(date +%s) -lt $PROFILE_TIME ]; do
    if ! check_k6_running; then
        echo "Load test completed early!"
        break
    fi
    sleep 30
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((ELAPSED * 100 / 900))
    echo "  $(date '+%H:%M:%S') - Elapsed: ${ELAPSED}s / 900s (${PERCENT}%)"
done

# Profile at 15-minute mark if still running
if check_k6_running; then
    echo ""
    echo "=== PROFILING AT 15-MINUTE MARK ==="
    echo "Time: $(date)"
    echo ""

    # 1. pprof CPU Profile (30 seconds sample)
    echo "--- Go pprof CPU Profile (30s sample) ---"
    echo "  Challenge Service: Capturing CPU profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/profile?seconds=30" -o "${RESULTS_DIR}/service_cpu_15min.pprof"; then
        echo "  ✓ Service CPU profile saved ($(du -h "${RESULTS_DIR}/service_cpu_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service CPU profile"
    fi

    echo "  Event Handler: Capturing CPU profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/profile?seconds=30" -o "${RESULTS_DIR}/handler_cpu_15min.pprof"; then
        echo "  ✓ Handler CPU profile saved ($(du -h "${RESULTS_DIR}/handler_cpu_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler CPU profile"
    fi
    echo ""

    # 2. pprof Heap Profile (memory allocation)
    echo "--- Go pprof Heap Profile ---"
    echo "  Challenge Service: Capturing heap profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/heap" -o "${RESULTS_DIR}/service_heap_15min.pprof"; then
        echo "  ✓ Service heap profile saved ($(du -h "${RESULTS_DIR}/service_heap_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service heap profile"
    fi

    echo "  Event Handler: Capturing heap profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/heap" -o "${RESULTS_DIR}/handler_heap_15min.pprof"; then
        echo "  ✓ Handler heap profile saved ($(du -h "${RESULTS_DIR}/handler_heap_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler heap profile"
    fi
    echo ""

    # 3. pprof Goroutine Profile
    echo "--- Go pprof Goroutine Profile ---"
    echo "  Challenge Service: Capturing goroutine profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/goroutine" -o "${RESULTS_DIR}/service_goroutine_15min.txt"; then
        echo "  ✓ Service goroutine profile saved ($(du -h "${RESULTS_DIR}/service_goroutine_15min.txt" | cut -f1))"
    else
        echo "  ✗ Failed to capture service goroutine profile"
    fi

    echo "  Event Handler: Capturing goroutine profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/goroutine" -o "${RESULTS_DIR}/handler_goroutine_15min.txt"; then
        echo "  ✓ Handler goroutine profile saved ($(du -h "${RESULTS_DIR}/handler_goroutine_15min.txt" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler goroutine profile"
    fi
    echo ""

    # 4. pprof Mutex Profile (contention)
    echo "--- Go pprof Mutex Profile ---"
    echo "  Challenge Service: Capturing mutex profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/mutex" -o "${RESULTS_DIR}/service_mutex_15min.pprof"; then
        echo "  ✓ Service mutex profile saved ($(du -h "${RESULTS_DIR}/service_mutex_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service mutex profile"
    fi

    echo "  Event Handler: Capturing mutex profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/mutex" -o "${RESULTS_DIR}/handler_mutex_15min.pprof"; then
        echo "  ✓ Handler mutex profile saved ($(du -h "${RESULTS_DIR}/handler_mutex_15min.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler mutex profile"
    fi
    echo ""

    # 5. Prometheus Metrics (for comparison)
    echo "--- Prometheus Metrics Snapshot ---"
    curl -s http://localhost:8080/metrics | grep -E "^(go_goroutines|process_cpu_seconds_total|process_resident_memory_bytes|http_requests_total)" | head -20
    echo ""

    curl -s http://localhost:8081/metrics | grep -E "^(go_goroutines|process_cpu_seconds_total|process_resident_memory_bytes)" | head -20
    echo ""

    # 6. Database Container Resource Usage
    echo "--- PostgreSQL Container Resource Usage ---"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" challenge-postgres > "${RESULTS_DIR}/postgres_stats_15min.txt"
    cat "${RESULTS_DIR}/postgres_stats_15min.txt"
    echo ""

    # 7. Database Performance Stats
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

    # 8. Docker Container Stats (CPU & Memory - All Services)
    echo "--- Docker Container Stats (15-min mark) ---"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" challenge-service challenge-event-handler challenge-postgres challenge-redis > "${RESULTS_DIR}/all_containers_stats_15min.txt"
    cat "${RESULTS_DIR}/all_containers_stats_15min.txt"
    echo ""

    # 9. Sample Initialize Latencies
    echo "--- Recent Initialize Latencies (last 10) ---"
    docker logs challenge-service --tail=100 2>&1 | grep "HTTP request.*initialize" | tail -10
    echo ""

    # List all captured files
    echo ""
    echo "📊 Profile files saved to: ${RESULTS_DIR}/"
    echo ""
    if ls "${RESULTS_DIR}"/*15min* 1> /dev/null 2>&1; then
        ls -lh "${RESULTS_DIR}"/*15min* | awk '{print "   " $9 " (" $5 ")"}'
    else
        echo "   ⚠️  No profile files found"
    fi
    echo ""
    echo "📖 To analyze pprof files:"
    echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/service_cpu_15min.pprof"
    echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/service_heap_15min.pprof"
    echo ""
else
    echo ""
    echo "⚠️  Load test completed before 15-minute mark - no profiles captured"
    echo ""
fi

# Wait for completion
echo ""
echo "Waiting for load test completion..."
while check_k6_running; do
    sleep 30
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((ELAPSED * 100 / 1860))
    echo "  $(date '+%H:%M:%S') - Elapsed: ${ELAPSED}s / 1860s (${PERCENT}%)"
done

echo ""
echo "=== Load Test Completed ==="
echo "End time: $(date)"
TOTAL_DURATION=$(($(date +%s) - START_TIME))
echo "Total duration: ${TOTAL_DURATION} seconds ($(($TOTAL_DURATION / 60)) minutes)"
echo ""
echo "Results saved to: ${RESULTS_DIR}/"
echo ""
echo "Next: Analyze results and compare with previous phases"
