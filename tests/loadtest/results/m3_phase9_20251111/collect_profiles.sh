#!/bin/bash
set -e

RESULTS_DIR="/home/ab/projects/extend-challenge-suite/tests/loadtest/results/m3_phase9_20251111"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Collecting profiling data at $(date)..."

# Backend Service (port 8080)
echo "Collecting backend service CPU profile..."
curl -s "http://localhost:8080/debug/pprof/profile?seconds=30" -o "$RESULTS_DIR/backend_cpu_profile_${TIMESTAMP}.pprof"

echo "Collecting backend service heap profile..."
curl -s "http://localhost:8080/debug/pprof/heap" -o "$RESULTS_DIR/backend_heap_profile_${TIMESTAMP}.pprof"

echo "Collecting backend service goroutine profile..."
curl -s "http://localhost:8080/debug/pprof/goroutine" -o "$RESULTS_DIR/backend_goroutine_profile_${TIMESTAMP}.pprof"

# Event Handler (port 8081)
echo "Collecting event handler CPU profile..."
curl -s "http://localhost:8081/debug/pprof/profile?seconds=30" -o "$RESULTS_DIR/eventhandler_cpu_profile_${TIMESTAMP}.pprof"

echo "Collecting event handler heap profile..."
curl -s "http://localhost:8081/debug/pprof/heap" -o "$RESULTS_DIR/eventhandler_heap_profile_${TIMESTAMP}.pprof"

echo "Collecting event handler goroutine profile..."
curl -s "http://localhost:8081/debug/pprof/goroutine" -o "$RESULTS_DIR/eventhandler_goroutine_profile_${TIMESTAMP}.pprof"

echo "Profiling data collected successfully!"
ls -lh "$RESULTS_DIR"/*profile*.pprof
