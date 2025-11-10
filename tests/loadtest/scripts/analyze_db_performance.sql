-- PostgreSQL Performance Analysis
-- Run after load test to analyze query performance
-- Usage: psql -U postgres -d challenge_db -f analyze_db_performance.sql

-- ============================================================================
-- Top 10 Slowest Queries
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Top 10 Slowest Queries (user_goal_progress table)'
\echo '==================================================================='

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

-- ============================================================================
-- Connection Pool Utilization
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Connection Pool Utilization'
\echo '==================================================================='

SELECT
  state,
  COUNT(*) as count
FROM pg_stat_activity
GROUP BY state;

-- ============================================================================
-- Table Statistics
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Table Statistics (user_goal_progress)'
\echo '==================================================================='

SELECT
  schemaname,
  tablename,
  n_tup_ins AS inserts,
  n_tup_upd AS updates,
  n_tup_del AS deletes,
  n_live_tup AS live_rows,
  n_dead_tup AS dead_rows,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE tablename = 'user_goal_progress';

-- ============================================================================
-- Index Usage
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Index Usage (user_goal_progress table)'
\echo '==================================================================='

SELECT
  indexrelname AS index_name,
  idx_scan AS index_scans,
  idx_tup_read AS tuples_read,
  idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE tablename = 'user_goal_progress';

-- ============================================================================
-- Cache Hit Ratio
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Cache Hit Ratio (should be > 95% for good performance)'
\echo '==================================================================='

SELECT
  sum(heap_blks_read) as heap_read,
  sum(heap_blks_hit)  as heap_hit,
  sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) * 100 AS cache_hit_ratio
FROM pg_statio_user_tables
WHERE schemaname = 'public';

-- ============================================================================
-- Database Size
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Database Size'
\echo '==================================================================='

SELECT
  pg_size_pretty(pg_database_size('challenge_db')) AS database_size,
  pg_size_pretty(pg_total_relation_size('user_goal_progress')) AS table_size;

-- ============================================================================
-- Active Queries (at time of analysis)
-- ============================================================================
\echo ''
\echo '==================================================================='
\echo 'Active Queries (snapshot at analysis time)'
\echo '==================================================================='

SELECT
  pid,
  now() - query_start AS duration,
  state,
  query
FROM pg_stat_activity
WHERE state != 'idle'
  AND query NOT ILIKE '%pg_stat_activity%'
ORDER BY duration DESC;
