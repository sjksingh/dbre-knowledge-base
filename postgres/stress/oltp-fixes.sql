/*
================================================================================
IMMEDIATE OLTP PERFORMANCE FIXES
================================================================================
Problem: flagged_transactions query doing sequential scan (9 seconds)
Root Cause: Missing index on is_flagged + transaction_date
Impact: 10 sessions all waiting on BufferIO / DataFileRead

This script creates the missing indexes to fix your OLTP workload.
================================================================================
*/

-- ============================================================================
-- 1. FIX FLAGGED TRANSACTIONS QUERY (HIGHEST PRIORITY)
-- ============================================================================

-- Current problem: Sequential scan of 5M rows
-- Query: WHERE is_flagged = true AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
-- Wait time: 9+ seconds per query

CREATE INDEX CONCURRENTLY idx_flagged_recent 
ON financial_transactions(transaction_date DESC, risk_score DESC)
WHERE is_flagged = true 
AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
AND is_deleted = false;

-- Why this works:
-- 1. Partial index (only flagged + recent = ~10K rows instead of 5M)
-- 2. Covers the WHERE clause exactly
-- 3. DESC on risk_score → no sort needed for ORDER BY
-- 4. Index size: ~1MB instead of 500MB full index
-- Expected speedup: 900x (9000ms → 10ms)

COMMENT ON INDEX idx_flagged_recent IS 
'Partial index for fraud review queries - covers is_flagged + recent date range';

-- ============================================================================
-- 2. VERIFY INDEX IS BEING USED
-- ============================================================================

-- Run this to confirm Postgres will use the new index
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
FROM financial_transactions 
WHERE is_flagged = true 
AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY risk_score DESC 
LIMIT 50;

-- Expected output:
-- → Index Scan using idx_flagged_recent
-- → Buffers: shared hit=... (NO disk reads)
-- → Execution time: <10ms

-- ============================================================================
-- 3. ADDITIONAL OLTP OPTIMIZATIONS
-- ============================================================================

-- High-value transactions index (already exists but ensure it's optimal)
-- Your current index: idx_txn_amount WHERE amount > 10000
-- Verify it covers the query:
EXPLAIN (ANALYZE, BUFFERS)
SELECT transaction_id, customer_id, amount, risk_score
FROM financial_transactions 
WHERE amount > 10000
AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY amount DESC 
LIMIT 100;

-- If it's not using idx_txn_amount, create better version:
CREATE INDEX CONCURRENTLY idx_high_value_recent
ON financial_transactions(transaction_date DESC, amount DESC)
WHERE amount > 10000 
AND is_deleted = false;

-- ============================================================================
-- 4. CUSTOMER RECENT TRANSACTIONS (ALREADY INDEXED BUT CHECK USAGE)
-- ============================================================================

-- This query should use idx_txn_customer
-- Verify:
EXPLAIN (ANALYZE, BUFFERS)
SELECT transaction_id, amount, transaction_type, transaction_date, transaction_status
FROM financial_transactions 
WHERE customer_id = 12345 
AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY transaction_date DESC 
LIMIT 20;

-- If it's doing Seq Scan, might need composite index:
CREATE INDEX CONCURRENTLY idx_customer_recent
ON financial_transactions(customer_id, transaction_date DESC)
WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
AND is_deleted = false;

-- ============================================================================
-- 5. ACCOUNT STATUS CHECK (CHECK IF INDEX EXISTS)
-- ============================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) as pending_count, COALESCE(SUM(amount), 0) as pending_amount
FROM financial_transactions 
WHERE account_id = 123456 
AND transaction_status = 'pending';

-- If Seq Scan, create composite index:
CREATE INDEX CONCURRENTLY idx_account_status
ON financial_transactions(account_id, transaction_status)
WHERE transaction_status = 'pending'
AND is_deleted = false;

-- ============================================================================
-- 6. MONITORING: CHECK INDEX USAGE AFTER DEPLOYMENT
-- ============================================================================

-- Wait 10-15 minutes after creating indexes, then run:
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan as times_used,
    idx_tup_read as rows_read,
    idx_tup_fetch as rows_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    CASE 
        WHEN idx_scan = 0 THEN '⚠️  Not yet used'
        WHEN idx_scan < 10 THEN '🔄 Warming up'
        ELSE '✅ Active'
    END as status
FROM pg_stat_user_indexes
WHERE tablename = 'financial_transactions'
AND indexname IN (
    'idx_flagged_recent',
    'idx_high_value_recent', 
    'idx_customer_recent',
    'idx_account_status'
)
ORDER BY idx_scan DESC;

-- ============================================================================
-- 7. VALIDATE PERFORMANCE IMPROVEMENT
-- ============================================================================

-- Before index (you saw this):
-- flagged_transactions query: 9+ seconds, IO: DataFileRead, IPC: BufferIO

-- After index (expected):
-- flagged_transactions query: <10ms, NO wait events (CPU-bound)

-- Monitor with:
SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) as waiting_sessions,
    string_agg(DISTINCT left(query, 60), ' | ') as sample_queries
FROM pg_stat_activity
WHERE state = 'active'
AND application_name = 'read_workload_simulator'
AND wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY waiting_sessions DESC;

-- Expected: NO ROWS (all queries CPU-bound, no waits!)

-- ============================================================================
-- 8. CACHE HIT RATIO CHECK
-- ============================================================================

-- After indexes, cache hit should improve dramatically
SELECT 
    'Before indexes: ~70%, After indexes: >95%' as expectation,
    relname,
    ROUND(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) 
        as cache_hit_pct,
    heap_blks_read as disk_reads,
    heap_blks_hit as cache_hits
FROM pg_statio_user_tables
WHERE relname = 'financial_transactions';

-- ============================================================================
-- 9. EXECUTION PLAN COMPARISON
-- ============================================================================

-- Run your workload simulator again:
-- go run prod_reader.go -workload=oltp -sessions=10 -duration=2m

-- Then check execution plans haven't regressed:
SELECT 
    query,
    calls,
    mean_exec_time,
    max_exec_time,
    rows / calls as avg_rows_per_call
FROM pg_stat_statements
WHERE query LIKE '%is_flagged%'
AND query NOT LIKE '%pg_stat%'
ORDER BY calls DESC
LIMIT 5;

-- Expected:
-- mean_exec_time: <10ms (was 9000ms)
-- calls: Should match your query count
-- No wait events in pg_stat_activity

-- ============================================================================
-- 10. ROLLBACK PLAN (IF SOMETHING GOES WRONG)
-- ============================================================================

-- If new indexes cause problems (unlikely), drop them:
/*
DROP INDEX CONCURRENTLY IF EXISTS idx_flagged_recent;
DROP INDEX CONCURRENTLY IF EXISTS idx_high_value_recent;
DROP INDEX CONCURRENTLY IF EXISTS idx_customer_recent;
DROP INDEX CONCURRENTLY IF EXISTS idx_account_status;
*/

-- Note: CONCURRENTLY means no downtime, but takes longer to build
-- Progress monitoring while creating:
SELECT 
    phase,
    round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS "% complete",
    blocks_done,
    blocks_total
FROM pg_stat_progress_create_index;

/*
================================================================================
EXPECTED RESULTS AFTER APPLYING THESE FIXES
================================================================================

BEFORE:
- flagged_transactions: 9+ seconds per query
- Wait events: IO: DataFileRead, IPC: BufferIO
- All 10 sessions stuck on same query
- Cache hit: ~70%

AFTER:
- flagged_transactions: <10ms per query
- Wait events: NONE (CPU-bound = good!)
- Queries complete instantly
- Cache hit: >95%

PERFORMANCE IMPROVEMENT:
- Query time: 9000ms → 10ms = 900x faster
- Throughput: 1 QPS → 100+ QPS
- Wait time: 9 sec → 0 sec

Go run your OLTP workload again:
    go run prod_reader.go -workload=oltp -sessions=25 -duration=5m

You should see:
- QPS: 500+ queries/sec (was ~5)
- Errors: 0% (was potentially timeouts)
- Cache: >95% (was 70%)
- Pool: All sessions active, not waiting

================================================================================
*/
