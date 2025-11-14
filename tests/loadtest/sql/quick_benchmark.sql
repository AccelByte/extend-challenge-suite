-- ================================================================================
-- Quick Initialize Performance Benchmark
-- ================================================================================
-- Purpose: Fast benchmark to identify the bottleneck in initialize endpoint
-- Runtime: ~30 seconds
-- ================================================================================

\timing on
\echo '================================================================================'
\echo 'Quick Initialize Performance Benchmark'
\echo '================================================================================'
\echo ''

-- ================================================================================
-- Test 1: Fast Path - COUNT Query
-- ================================================================================
\echo '>>> Test 1: GetUserGoalCount (Fast Path Check)'
\echo 'Testing: SELECT COUNT(*) FROM user_goal_progress WHERE user_id = $1'
\echo ''

-- Warm up (ensure pages are in cache)
SELECT COUNT(*) FROM user_goal_progress WHERE user_id = 'user-000001';

-- Test 10 times and measure
DO $$
DECLARE
    start_time TIMESTAMP;
    total_time INTERVAL := '0 seconds';
    i INT;
    result INT;
BEGIN
    FOR i IN 1..10 LOOP
        start_time := clock_timestamp();
        SELECT COUNT(*) INTO result FROM user_goal_progress WHERE user_id = 'user-000001';
        total_time := total_time + (clock_timestamp() - start_time);
    END LOOP;

    RAISE NOTICE 'COUNT query (10 iterations):';
    RAISE NOTICE '  Total time: % ms', EXTRACT(EPOCH FROM total_time) * 1000;
    RAISE NOTICE '  Average: %.2f ms', EXTRACT(EPOCH FROM total_time) * 100;
    RAISE NOTICE '  Result: % goals', result;
END $$;

\echo ''
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM user_goal_progress WHERE user_id = 'user-000001';

-- ================================================================================
-- Test 2: Fast Path - SELECT Query
-- ================================================================================
\echo ''
\echo '>>> Test 2: GetActiveGoals (Return Active Goals)'
\echo 'Testing: SELECT * FROM user_goal_progress WHERE user_id = $1 AND is_active = true'
\echo ''

-- Test 10 times and measure
DO $$
DECLARE
    start_time TIMESTAMP;
    total_time INTERVAL := '0 seconds';
    i INT;
    result_count INT;
BEGIN
    FOR i IN 1..10 LOOP
        start_time := clock_timestamp();
        SELECT COUNT(*) INTO result_count
        FROM user_goal_progress
        WHERE user_id = 'user-000001' AND is_active = true;
        total_time := total_time + (clock_timestamp() - start_time);
    END LOOP;

    RAISE NOTICE 'SELECT query (10 iterations):';
    RAISE NOTICE '  Total time: % ms', EXTRACT(EPOCH FROM total_time) * 1000;
    RAISE NOTICE '  Average: %.2f ms', EXTRACT(EPOCH FROM total_time) * 100;
    RAISE NOTICE '  Result: % active goals', result_count;
END $$;

\echo ''
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, goal_id, challenge_id, namespace, progress, status,
       completed_at, claimed_at, created_at, updated_at,
       is_active, assigned_at, expires_at
FROM user_goal_progress
WHERE user_id = 'user-000001' AND is_active = true
ORDER BY challenge_id, goal_id;

-- ================================================================================
-- Test 3: Slow Path - BulkInsert (10 records)
-- ================================================================================
\echo ''
\echo '>>> Test 3: BulkInsert (10 Records - M3 Phase 9)'
\echo 'Testing insert of 10 default-assigned goals for new user'
\echo ''

-- Test 5 times and measure
DO $$
DECLARE
    start_time TIMESTAMP;
    total_time INTERVAL := '0 seconds';
    i INT;
    test_user TEXT;
BEGIN
    FOR i IN 1..5 LOOP
        test_user := 'bench-10-' || i;
        start_time := clock_timestamp();

        INSERT INTO user_goal_progress (
            user_id, goal_id, challenge_id, namespace,
            progress, status, completed_at, claimed_at,
            created_at, updated_at,
            is_active, assigned_at, expires_at
        ) VALUES
            (test_user, 'goal-001', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-002', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-003', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-004', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-005', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-006', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-007', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-008', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-009', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL),
            (test_user, 'goal-010', 'challenge-001', 'test', 0, 'not_started', NULL, NULL, NOW(), NOW(), true, NOW(), NULL)
        ON CONFLICT (user_id, goal_id) DO NOTHING;

        total_time := total_time + (clock_timestamp() - start_time);

        -- Clean up
        DELETE FROM user_goal_progress WHERE user_id = test_user;
    END LOOP;

    RAISE NOTICE 'BulkInsert 10 records (5 iterations):';
    RAISE NOTICE '  Total time: % ms', EXTRACT(EPOCH FROM total_time) * 1000;
    RAISE NOTICE '  Average: %.2f ms', EXTRACT(EPOCH FROM total_time) * 200;
END $$;

-- ================================================================================
-- Test 4: Slow Path - BulkInsert (500 records)
-- ================================================================================
\echo ''
\echo '>>> Test 4: BulkInsert (500 Records - Old Behavior)'
\echo 'Testing insert of 500 goals (Phase 8 behavior that caused 17.58s p95)'
\echo ''

-- Test once (takes longer)
DO $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    duration_ms NUMERIC;
    values_list TEXT := '';
    sql_query TEXT;
    i INT;
    test_user TEXT := 'bench-500-test';
BEGIN
    -- Build VALUES clause with 500 rows
    FOR i IN 1..500 LOOP
        IF i > 1 THEN
            values_list := values_list || ',';
        END IF;
        values_list := values_list || format(
            '(%L, %L, %L, %L, 0, %L, NULL, NULL, NOW(), NOW(), true, NOW(), NULL)',
            test_user,
            'goal-' || lpad(i::TEXT, 3, '0'),
            'challenge-001',
            'test',
            'not_started'
        );
    END LOOP;

    sql_query := 'INSERT INTO user_goal_progress ' ||
                 '(user_id, goal_id, challenge_id, namespace, progress, status, completed_at, claimed_at, created_at, updated_at, is_active, assigned_at, expires_at) ' ||
                 'VALUES ' || values_list ||
                 ' ON CONFLICT (user_id, goal_id) DO NOTHING';

    start_time := clock_timestamp();
    EXECUTE sql_query;
    end_time := clock_timestamp();

    duration_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

    RAISE NOTICE 'BulkInsert 500 records (1 iteration):';
    RAISE NOTICE '  Time: %.2f ms', duration_ms;
    RAISE NOTICE '  Per-row: %.3f ms', duration_ms / 500;

    -- Clean up
    DELETE FROM user_goal_progress WHERE user_id = test_user;
END $$;

-- ================================================================================
-- Test 5: Combined Fast Path (Real Scenario)
-- ================================================================================
\echo ''
\echo '>>> Test 5: Combined Fast Path (COUNT + SELECT)'
\echo 'This simulates the actual initialize endpoint for returning users'
\echo ''

DO $$
DECLARE
    start_time TIMESTAMP;
    total_time INTERVAL := '0 seconds';
    i INT;
    user_count INT;
    goal_count INT;
    test_user TEXT;
BEGIN
    FOR i IN 0..9 LOOP
        test_user := 'user-' || lpad(i::TEXT, 6, '0');
        start_time := clock_timestamp();

        -- Query 1: GetUserGoalCount
        SELECT COUNT(*) INTO user_count FROM user_goal_progress WHERE user_id = test_user;

        -- Query 2: GetActiveGoals (only if count > 0)
        IF user_count > 0 THEN
            SELECT COUNT(*) INTO goal_count
            FROM user_goal_progress
            WHERE user_id = test_user AND is_active = true;
        END IF;

        total_time := total_time + (clock_timestamp() - start_time);
    END LOOP;

    RAISE NOTICE 'Combined Fast Path (10 users):';
    RAISE NOTICE '  Total time: % ms', EXTRACT(EPOCH FROM total_time) * 1000;
    RAISE NOTICE '  Average per user: %.2f ms', EXTRACT(EPOCH FROM total_time) * 100;
    RAISE NOTICE '  Expected p95 at 300 RPS: ~%.2f ms', EXTRACT(EPOCH FROM total_time) * 100 * 1.5;
END $$;

-- ================================================================================
-- Summary
-- ================================================================================
\echo ''
\echo '================================================================================'
\echo 'Benchmark Summary'
\echo '================================================================================'
\echo ''
\echo 'Expected Results:'
\echo '  - Test 1 (COUNT):        <1ms (index scan on user_id)'
\echo '  - Test 2 (SELECT):       <5ms (index scan + fetch ~500 rows)'
\echo '  - Test 3 (INSERT 10):    <5ms (small batch, good performance)'
\echo '  - Test 4 (INSERT 500):   10-50ms (large batch, expect higher overhead)'
\echo '  - Test 5 (Combined):     <10ms (fast path should be very fast)'
\echo ''
\echo 'If results are significantly worse:'
\echo '  - Test 1/2 slow: Index not being used, check EXPLAIN ANALYZE output'
\echo '  - Test 3/4 slow: Check for table bloat, autovacuum, or lock contention'
\echo '  - Test 5 slow: Something is wrong with fast path logic'
\echo ''
\echo 'Load Test Context (Phase 16 failure):'
\echo '  - Init phase p95: 17,580ms (17.58s) - should be <100ms'
\echo '  - Gameplay init p95: 20,430ms (20.43s) - should be <50ms'
\echo '  - If Test 5 shows <10ms, the problem is NOT in the SQL queries'
\echo '  - If Test 5 shows >1000ms, we found the bottleneck'
\echo ''
\echo '================================================================================'

\timing off
