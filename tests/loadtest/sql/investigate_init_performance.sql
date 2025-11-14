-- ================================================================================
-- Initialize Endpoint Performance Investigation SQL
-- ================================================================================
-- Purpose: Reproduce the 17.58s p95 initialization latency using pure SQL analysis
-- Date: 2025-11-13
-- Context: M3 Phase 16 load test revealed critical performance issues
--
-- Test Scenario:
-- - 10,001 users in database
-- - Average 374 goals per user (7,442 users with 500 goals)
-- - Total rows: 3,741,271
-- - Database size: 1.3 GB
--
-- Problem:
-- - Init phase p95: 17.58s (target: <100ms) - 176x over target
-- - Gameplay init p95: 20.43s (target: <50ms) - 408x over target
-- - 6% failure rate (EOF errors, timeouts)
--
-- Hypothesis:
-- 1. Fast path check (GetUserGoalCount) may be slow with 3.7M rows
-- 2. GetActiveGoals may trigger sequential scans despite indexes
-- 3. BulkInsert for new users may have high overhead
-- ================================================================================

\timing on
\x off

-- ================================================================================
-- PART 1: Analyze Current Database State
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 1: Database State Analysis'
\echo '================================================================================'
\echo ''

-- 1.1: Table statistics
\echo '>>> 1.1 Table Statistics'
SELECT
    pg_size_pretty(pg_table_size('user_goal_progress')) as table_size,
    pg_size_pretty(pg_indexes_size('user_goal_progress')) as indexes_size,
    pg_size_pretty(pg_total_relation_size('user_goal_progress')) as total_size,
    COUNT(*) as total_rows,
    COUNT(DISTINCT user_id) as unique_users
FROM user_goal_progress;

-- 1.2: Index usage statistics
\echo ''
\echo '>>> 1.2 Index Usage Statistics'
SELECT
    indexrelname as index_name,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
  AND tablename = 'user_goal_progress'
ORDER BY idx_scan DESC;

-- 1.3: Sequential vs index scan ratio
\echo ''
\echo '>>> 1.3 Sequential vs Index Scan Ratio'
SELECT
    schemaname,
    tablename,
    seq_scan as sequential_scans,
    seq_tup_read as seq_rows_read,
    idx_scan as index_scans,
    idx_tup_fetch as idx_rows_fetched,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct
FROM pg_stat_user_tables
WHERE tablename = 'user_goal_progress';

-- 1.4: Goals per user distribution
\echo ''
\echo '>>> 1.4 Goals Per User Distribution'
SELECT
    goal_count,
    COUNT(*) as num_users,
    pg_size_pretty(CAST(goal_count * COUNT(*) AS BIGINT) * 1024) as approx_storage
FROM (
    SELECT user_id, COUNT(*) as goal_count
    FROM user_goal_progress
    GROUP BY user_id
) t
GROUP BY goal_count
ORDER BY goal_count DESC
LIMIT 10;

-- ================================================================================
-- PART 2: Test Fast Path (Returning Users - 99% of Requests)
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 2: Fast Path Analysis (Returning Users)'
\echo '================================================================================'
\echo ''
\echo 'Testing the two queries executed for returning users:'
\echo '1. GetUserGoalCount (COUNT query)'
\echo '2. GetActiveGoals (SELECT query with is_active = true)'
\echo ''

-- 2.1: Test GetUserGoalCount with EXPLAIN ANALYZE
-- This is query #1 in the fast path
\echo '>>> 2.1 GetUserGoalCount Performance (Fast Path Check)'
\echo 'Query: SELECT COUNT(*) FROM user_goal_progress WHERE user_id = $1'
\echo ''

-- Test with a user that has 500 goals (typical case)
EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE)
SELECT COUNT(*) FROM user_goal_progress WHERE user_id = 'user-000001';

-- 2.2: Test GetActiveGoals with EXPLAIN ANALYZE
-- This is query #2 in the fast path
\echo ''
\echo '>>> 2.2 GetActiveGoals Performance (Return Active Goals)'
\echo 'Query: SELECT * FROM user_goal_progress WHERE user_id = $1 AND is_active = true'
\echo ''

EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE)
SELECT user_id, goal_id, challenge_id, namespace, progress, status,
       completed_at, claimed_at, created_at, updated_at,
       is_active, assigned_at, expires_at
FROM user_goal_progress
WHERE user_id = 'user-000001' AND is_active = true
ORDER BY challenge_id, goal_id;

-- 2.3: Test fast path combined (simulating actual endpoint)
\echo ''
\echo '>>> 2.3 Fast Path Combined (COUNT + SELECT)'
\echo 'This simulates the full fast path execution'
\echo ''

DO $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    count_time INTERVAL;
    select_time INTERVAL;
    total_time INTERVAL;
    user_count INT;
    goal_count INT;
BEGIN
    -- Query 1: GetUserGoalCount
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO user_count FROM user_goal_progress WHERE user_id = 'user-000001';
    count_time := clock_timestamp() - start_time;

    -- Query 2: GetActiveGoals (only if count > 0)
    IF user_count > 0 THEN
        start_time := clock_timestamp();
        SELECT COUNT(*) INTO goal_count
        FROM user_goal_progress
        WHERE user_id = 'user-000001' AND is_active = true;
        select_time := clock_timestamp() - start_time;
    END IF;

    total_time := count_time + select_time;

    RAISE NOTICE 'Fast Path Timing:';
    RAISE NOTICE '  COUNT query:  % (%.3f ms)', count_time, EXTRACT(EPOCH FROM count_time) * 1000;
    RAISE NOTICE '  SELECT query: % (%.3f ms)', select_time, EXTRACT(EPOCH FROM select_time) * 1000;
    RAISE NOTICE '  TOTAL:        % (%.3f ms)', total_time, EXTRACT(EPOCH FROM total_time) * 1000;
    RAISE NOTICE '  User count: %, Active goals: %', user_count, goal_count;
END $$;

-- ================================================================================
-- PART 3: Test Slow Path (New Users - 1% of Requests)
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 3: Slow Path Analysis (New Users)'
\echo '================================================================================'
\echo ''
\echo 'Testing bulk insert for first-time initialization'
\echo ''

-- 3.1: Test BulkInsert with 10 records (M3 Phase 9 default-assigned goals)
\echo '>>> 3.1 BulkInsert Performance (10 Records - Typical M3 Case)'
\echo ''

BEGIN;

EXPLAIN (ANALYZE, BUFFERS, TIMING)
INSERT INTO user_goal_progress (
    user_id, goal_id, challenge_id, namespace,
    progress, status, completed_at, claimed_at,
    created_at, updated_at,
    is_active, assigned_at, expires_at
) VALUES
    ('test-bulk-10-user', 'goal-001', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-002', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-003', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-004', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-005', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-006', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-007', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-008', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-009', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
    ('test-bulk-10-user', 'goal-010', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL)
ON CONFLICT (user_id, goal_id) DO NOTHING;

ROLLBACK;

-- 3.2: Test BulkInsert with 500 records (Phase 8 case - before lazy materialization)
\echo ''
\echo '>>> 3.2 BulkInsert Performance (500 Records - Old Behavior)'
\echo 'Note: This simulates the old behavior that caused 17.58s p95 latency'
\echo ''

-- Generate 500-row insert (using a helper function to avoid typing 500 rows)
DO $$
DECLARE
    sql_query TEXT;
    values_list TEXT := '';
    i INT;
BEGIN
    -- Build VALUES clause with 500 rows
    FOR i IN 1..500 LOOP
        IF i > 1 THEN
            values_list := values_list || ',';
        END IF;
        values_list := values_list || format(
            '(''test-bulk-500-user'', ''goal-%s'', ''challenge-001'', ''test'', 0, ''not_started'', NULL, NULL, NOW(), NOW(), true, NOW(), NULL)',
            lpad(i::TEXT, 3, '0')
        );
    END LOOP;

    sql_query := 'EXPLAIN (ANALYZE, BUFFERS, TIMING) ' ||
                 'INSERT INTO user_goal_progress ' ||
                 '(user_id, goal_id, challenge_id, namespace, progress, status, completed_at, claimed_at, created_at, updated_at, is_active, assigned_at, expires_at) ' ||
                 'VALUES ' || values_list ||
                 ' ON CONFLICT (user_id, goal_id) DO NOTHING';

    EXECUTE sql_query;
END $$;

-- ================================================================================
-- PART 4: Benchmark Different Batch Sizes
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 4: Batch Size Benchmark'
\echo '================================================================================'
\echo ''
\echo 'Testing insert performance with different batch sizes'
\echo ''

-- 4.1: Benchmark function
CREATE OR REPLACE FUNCTION benchmark_bulk_insert(batch_size INT, num_iterations INT DEFAULT 5)
RETURNS TABLE(
    batch_size INT,
    avg_ms NUMERIC,
    min_ms NUMERIC,
    max_ms NUMERIC,
    p95_ms NUMERIC
) AS $$
DECLARE
    timings NUMERIC[];
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    duration_ms NUMERIC;
    values_list TEXT;
    sql_query TEXT;
    i INT;
    j INT;
    test_user_id TEXT;
BEGIN
    timings := ARRAY[]::NUMERIC[];

    FOR j IN 1..num_iterations LOOP
        test_user_id := 'bench-user-' || batch_size || '-' || j;
        values_list := '';

        -- Build VALUES clause
        FOR i IN 1..batch_size LOOP
            IF i > 1 THEN
                values_list := values_list || ',';
            END IF;
            values_list := values_list || format(
                '(%L, %L, %L, %L, 0, %L, NULL, NULL, NOW(), NOW(), true, NOW(), NULL)',
                test_user_id,
                'goal-' || lpad(i::TEXT, 4, '0'),
                'challenge-001',
                'test',
                'not_started'
            );
        END LOOP;

        sql_query := 'INSERT INTO user_goal_progress ' ||
                     '(user_id, goal_id, challenge_id, namespace, progress, status, completed_at, claimed_at, created_at, updated_at, is_active, assigned_at, expires_at) ' ||
                     'VALUES ' || values_list ||
                     ' ON CONFLICT (user_id, goal_id) DO NOTHING';

        -- Time the insert
        start_time := clock_timestamp();
        EXECUTE sql_query;
        end_time := clock_timestamp();

        duration_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
        timings := array_append(timings, duration_ms);

        -- Clean up
        EXECUTE format('DELETE FROM user_goal_progress WHERE user_id = %L', test_user_id);
    END LOOP;

    -- Calculate statistics
    SELECT
        batch_size,
        ROUND(AVG(t), 2),
        ROUND(MIN(t), 2),
        ROUND(MAX(t), 2),
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t), 2)
    INTO benchmark_bulk_insert.batch_size, avg_ms, min_ms, max_ms, p95_ms
    FROM UNNEST(timings) AS t;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- 4.2: Run benchmarks
\echo '>>> 4.2 Batch Size Benchmark Results'
\echo 'Testing batch sizes: 10, 50, 100, 200, 500'
\echo 'Each size tested 5 times, reporting avg/min/max/p95'
\echo ''

SELECT * FROM benchmark_bulk_insert(10);
SELECT * FROM benchmark_bulk_insert(50);
SELECT * FROM benchmark_bulk_insert(100);
SELECT * FROM benchmark_bulk_insert(200);
SELECT * FROM benchmark_bulk_insert(500);

-- 4.3: Summary table
\echo ''
\echo '>>> 4.3 Batch Size Performance Summary'
\echo ''

SELECT
    b.batch_size,
    b.avg_ms || ' ms' as avg_time,
    b.p95_ms || ' ms' as p95_time,
    ROUND(b.avg_ms / NULLIF(b10.avg_ms, 0), 2) || 'x' as slowdown_vs_10,
    ROUND(b.avg_ms / b.batch_size, 3) || ' ms' as ms_per_row
FROM
    benchmark_bulk_insert(10) b10
    CROSS JOIN LATERAL (
        SELECT * FROM benchmark_bulk_insert(10)
        UNION ALL SELECT * FROM benchmark_bulk_insert(50)
        UNION ALL SELECT * FROM benchmark_bulk_insert(100)
        UNION ALL SELECT * FROM benchmark_bulk_insert(200)
        UNION ALL SELECT * FROM benchmark_bulk_insert(500)
    ) b
ORDER BY b.batch_size;

-- Cleanup
DROP FUNCTION benchmark_bulk_insert(INT, INT);

-- ================================================================================
-- PART 5: Index Analysis
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 5: Index Analysis'
\echo '================================================================================'
\echo ''

-- 5.1: Check if indexes are being used correctly
\echo '>>> 5.1 Index Usage for Fast Path Queries'
\echo ''

-- Test COUNT query index usage
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM user_goal_progress WHERE user_id = 'user-000001';

\echo ''

-- Test SELECT query index usage
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_goal_progress
WHERE user_id = 'user-000001' AND is_active = true;

-- 5.2: Check for missing indexes
\echo ''
\echo '>>> 5.2 Check for Missing Indexes (pg_stat_statements)'
\echo 'Note: Requires pg_stat_statements extension'
\echo ''

SELECT
    calls,
    ROUND(mean_exec_time::numeric, 2) as avg_ms,
    ROUND(max_exec_time::numeric, 2) as max_ms,
    ROUND(total_exec_time::numeric, 2) as total_ms,
    LEFT(query, 120) as query_preview
FROM pg_stat_statements
WHERE query LIKE '%user_goal_progress%'
  AND query NOT LIKE '%pg_stat%'
  AND query NOT LIKE '%EXPLAIN%'
ORDER BY mean_exec_time DESC
LIMIT 20;

-- ================================================================================
-- PART 6: Concurrency Simulation
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 6: Concurrency Simulation'
\echo '================================================================================'
\echo ''
\echo 'Simulating concurrent initialize requests'
\echo ''

-- 6.1: Create test function for concurrent fast path
CREATE OR REPLACE FUNCTION test_concurrent_fast_path(num_users INT)
RETURNS TABLE(
    user_id TEXT,
    count_ms NUMERIC,
    select_ms NUMERIC,
    total_ms NUMERIC
) AS $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    user_count INT;
    i INT;
BEGIN
    FOR i IN 0..num_users-1 LOOP
        user_id := 'user-' || lpad(i::TEXT, 6, '0');

        -- COUNT query
        start_time := clock_timestamp();
        SELECT COUNT(*) INTO user_count FROM user_goal_progress WHERE user_goal_progress.user_id = test_concurrent_fast_path.user_id;
        end_time := clock_timestamp();
        count_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

        -- SELECT query (only if count > 0)
        IF user_count > 0 THEN
            start_time := clock_timestamp();
            PERFORM * FROM user_goal_progress
            WHERE user_goal_progress.user_id = test_concurrent_fast_path.user_id AND is_active = true;
            end_time := clock_timestamp();
            select_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
        ELSE
            select_ms := 0;
        END IF;

        total_ms := count_ms + select_ms;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 6.2: Test with 100 users (simulating load)
\echo '>>> 6.2 Fast Path Performance Under Load (100 Users)'
\echo ''

SELECT
    COUNT(*) as num_requests,
    ROUND(AVG(total_ms), 2) as avg_ms,
    ROUND(MIN(total_ms), 2) as min_ms,
    ROUND(MAX(total_ms), 2) as max_ms,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_ms), 2) as p50_ms,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_ms), 2) as p95_ms,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_ms), 2) as p99_ms
FROM test_concurrent_fast_path(100);

-- Cleanup
DROP FUNCTION test_concurrent_fast_path(INT);

-- ================================================================================
-- PART 7: Recommendations
-- ================================================================================

\echo ''
\echo '================================================================================'
\echo 'PART 7: Analysis Summary and Recommendations'
\echo '================================================================================'
\echo ''
\echo 'Based on the analysis above, we should see:'
\echo ''
\echo '1. Fast Path (GetUserGoalCount + GetActiveGoals):'
\echo '   - Expected: <5ms for COUNT + <10ms for SELECT = <15ms total'
\echo '   - If > 100ms: Index not being used, or table bloat'
\echo ''
\echo '2. Slow Path (BulkInsert):'
\echo '   - 10 records: <5ms (M3 Phase 9 default-assigned goals)'
\echo '   - 500 records: 10-30ms (old behavior, should not happen in M3)'
\echo ''
\echo '3. Batch Size Impact:'
\echo '   - Linear scaling: 500 records should be ~10x slower than 50 records'
\echo '   - Non-linear scaling: Indicates ON CONFLICT or index overhead'
\echo ''
\echo '4. Concurrency:'
\echo '   - p95 should remain <50ms even with 100 concurrent users'
\echo '   - If p95 > 1s: Contention on indexes or locks'
\echo ''
\echo 'Next Steps:'
\echo '  - If fast path is slow: Add index on (user_id) for COUNT queries'
\echo '  - If bulk insert scales badly: Consider batching in application code'
\echo '  - If concurrency is issue: Check pg_stat_activity for locks'
\echo '  - If ON CONFLICT is slow: Consider checking existence before insert'
\echo ''
\echo '================================================================================'

\timing off
