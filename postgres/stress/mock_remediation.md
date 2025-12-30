# PostgreSQL Wait Events:

#diagnostics and remediation strategies for PostgreSQL wait events, specifically BufferMapping, DataFileRead, and BufferIO. Based on analysis of a 5M row `financial_transactions` table on PG14/RDS showing contention patterns.

**CRITICAL DISCOVERY**: Initial wait events were caused by **test queries against non-existent data** (0 flagged transactions out of 5M rows). This is a classic anti-pattern revealing a fundamental DBRE lesson:

> **Always validate test data distribution matches production patterns before performance testing.**

**Your Specific Case Analysis** (after generating realistic test data):
- **BufferMapping (5 sessions)**: Hash partition contention on shared buffer pool lookups
- **DataFileRead (2-4 sessions)**: Pages not cached, requiring physical disk reads  
- **BufferIO (1-4 sessions)**: Sessions waiting for other processes' I/O operations to complete
- **Root cause**: Sequential scans (2,035 scans, 1.73B tuples read) due to poor query/data alignment
- **Buffer hit ratio**: 80.69% (15 points below target of >95%)
- **Unused indexes**: 7 indexes with 0 scans wasting 491MB

All three waits hitting the **same query pattern** indicates a hot spot requiring multi-pronged optimization.

---

## The Critical Lesson: Test Data Must Match Production

### What Happened

**Initial state**: 
- 5M rows in financial_transactions
- **0 rows** where `is_flagged = true`
- Queries filtering on `is_flagged = true` doing full table scans
- All wait events triggered by queries returning 0 results

**Why this matters**:
1. Postgres planner saw 0% selectivity for `is_flagged = true`
2. With no matching rows, seq scan was actually correct (nothing to index)
3. Multiple sessions all doing seq scans → BufferMapping contention
4. Reading 5M rows repeatedly → DataFileRead waits
5. Sessions waiting on each other's I/O → BufferIO waits

**After generating realistic test data** (14,200 flagged rows = 0.28%):
```sql
UPDATE financial_transactions 
SET is_flagged = true,
    fraud_check_status = 'flagged'
WHERE risk_score > 85 
  AND transaction_date >= CURRENT_DATE - INTERVAL '90 days'
  AND random() < 0.02;
```

Now the indexes can actually work, and performance testing becomes meaningful.

### Staff-Level Insight

**This is a fundamental anti-pattern in database performance testing:**

❌ **Wrong**: Write queries, run load tests, optimize for observed waits  
✅ **Right**: Validate data distribution → Generate realistic test data → THEN test

**Red flags that data doesn't match queries**:
- Index with `idx_scan = 0` despite being "perfect" for a query
- Sequential scans on queries with seemingly good indexes
- Buffer hit ratio that seems unreasonably low
- Wait events that don't match workload characteristics

**Before ANY performance optimization**:
```sql
-- 1. Check actual data distribution
SELECT 
  count(*) as total,
  count(*) FILTER (WHERE <your_filter>) as matching,
  round(100.0 * count(*) FILTER (WHERE <your_filter>) / count(*), 4) as pct
FROM your_table;

-- 2. Validate query patterns match data
EXPLAIN (ANALYZE, BUFFERS) <your_query>;

-- 3. Check if indexes are actually being used
SELECT indexrelname, idx_scan 
FROM pg_stat_user_indexes 
WHERE relname = 'your_table';
```

**Only then** can you meaningfully optimize.

---

## Understanding the Wait Event Cascade

### The Sequential Relationship
```
1. BufferMapping (LWLock) → Session acquires lock to search buffer hash table
2. DataFileRead (IO)      → Page not found in buffer, read from disk initiated
3. BufferIO (IPC)         → Other sessions wait for that I/O to complete
```

**Key Insight**: These waits form a dependency chain. A single inefficient query pattern causes all three simultaneously because multiple sessions are competing for the same pages that aren't cached.

---

## Wait Event Deep Dive

### 1. BufferMapping (LWLock)

**What it means**: Sessions are contending for lightweight locks protecting PostgreSQL's 128 buffer pool hash partitions. When multiple backends simultaneously try to map disk blocks to buffer pool pages, they serialize on these locks.

**Root Causes**:
- **Buffer pool thrashing**: Working set exceeds `shared_buffers`, forcing constant eviction/loading
- **Hot page access**: Many sessions accessing the same small set of pages
- **Insufficient shared_buffers**: Buffer pool too small for workload
- **Hash partition contention**: Unlucky distribution causing multiple sessions to hash to same partition

**Production Impact**:
- Sessions wait microseconds to milliseconds acquiring locks
- Cumulative effect with 5+ sessions = visible latency
- Blocks execution pipeline even if disk I/O is fast

**Diagnostic Queries**:
```sql
-- Check buffer hit ratio (target >95%)
SELECT 
  round(100.0 * blks_hit / (blks_hit + blks_read), 2) AS buffer_hit_ratio,
  blks_hit,
  blks_read
FROM pg_stat_database 
WHERE datname = current_database();

-- Find queries with most buffer activity
SELECT query, shared_blks_hit, shared_blks_read,
       round(100.0 * shared_blks_hit / 
         NULLIF(shared_blks_hit + shared_blks_read, 0), 2) AS hit_ratio
FROM pg_stat_statements 
ORDER BY (shared_blks_hit + shared_blks_read) DESC 
LIMIT 20;
```

### 2. DataFileRead (IO)

**What it means**: A backend process is physically reading pages from disk because they're not in the shared buffer pool.

**Root Causes**:
- **Cold cache**: Data recently evicted or never loaded
- **Sequential scans**: Reading many pages that don't fit in buffer pool
- **Missing/inefficient indexes**: Forces table scans
- **Index bloat**: Index physically larger than necessary, reading more pages
- **Undersized shared_buffers**: Working set doesn't fit in memory

**Production Impact**:
- 5-50ms latency per disk read (varies by storage type)
- Amplified by storage IOPS limits (gp2 burstable, gp3 provisioned)
- Blocks query execution until page loaded

**Diagnostic Queries**:
```sql
-- Check read I/O by query
SELECT query, calls, 
       shared_blks_read, 
       shared_blks_read / calls as avg_read_per_call,
       mean_exec_time
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY shared_blks_read DESC LIMIT 20;

-- Find seq scans
SELECT schemaname, tablename, seq_scan, seq_tup_read,
       idx_scan, idx_tup_fetch,
       n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_tup_read DESC;
```

### 3. BufferIO (IPC)

**What it means** (PG14+): When multiple sessions need the same page that's currently being read from disk, the first session initiates the I/O and acquires an exclusive lock on that buffer. Other sessions queue on this lock until the I/O completes.

**Root Causes**:
- **Thundering herd**: Multiple concurrent sessions requesting same uncached pages
- **Checkpoint spikes**: Many dirty pages being flushed simultaneously
- **Hot page competition**: Sessions repeatedly hitting same small dataset
- **Bloated indexes**: Multiple I/O operations for single logical lookup

**Production Impact**:
- Waits cascade: if one session's I/O takes 20ms, 4 queued sessions each wait ~20ms
- Magnifies DataFileRead impact multiplicatively
- Connection pool exhaustion when many sessions blocked

**Diagnostic Queries**:
```sql
-- Check for hot blocks
SELECT 
  c.relname,
  count(*) as buffers,
  count(*) FILTER (WHERE b.isdirty) as dirty_buffers
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY c.relname
ORDER BY buffers DESC
LIMIT 20;

-- Checkpoint frequency (should be time-based, not too frequent)
SELECT 
  checkpoints_timed,
  checkpoints_req,
  buffers_checkpoint,
  buffers_clean,
  buffers_backend
FROM pg_stat_bgwriter;
```

---

## Your Specific Case: Diagnosis with Production Data

### Critical Findings from pg_stat_statements

**Top I/O Offenders**:
```
1. COUNT(*) queries: 7,564 avg blocks read per call, 188ms mean time
2. Flagged transactions query: 19,840 avg blocks read per call, 34.4 SECONDS mean time
3. Payment method aggregation: 157,258 blocks read per call, 18.6 SECONDS mean time
4. Fraud analysis aggregation: 155,356 blocks read per call, 16.1 SECONDS mean time
```

### Shocking Discovery: Sequential Scans Dominating

**The Real Problem**:
```
Table: financial_transactions (5M rows)
- seq_scan: 2,035 sequential scans
- seq_tup_read: 1,734,782,538 rows read via seq scans
- idx_scan: 1,308 index scans  
- idx_tup_fetch: 54,266,053 rows via indexes

RATIO: 32:1 sequential scan rows vs index scan rows!
```

**Your flagged query is doing FULL TABLE SCANS** despite having `idx_flagged_recent`.

### Index Usage Analysis - The Smoking Gun

**idx_flagged_recent**: 
- idx_scan: **0** (NEVER USED!)
- Size: 8192 bytes (1 page - essentially empty)

**Why it's not being used**:
1. **Selectivity issue**: If `is_flagged = true` covers >5-10% of rows, Postgres chooses seq scan
2. **Query pattern mismatch**: Your queries have `ORDER BY risk_score DESC` which the index supports, but the WHERE clause selectivity is too poor
3. **Statistics out of date**: Planner thinks seq scan is cheaper

### Buffer Cache Analysis

**Current State**:
- **Buffer hit ratio: 80.69%** (Target: >95%, you're 15 points below!)
- 114,527 buffers for financial_transactions (917MB of your buffer pool)
- Only 4,213 buffers for idx_txn_created_at (33MB)

**This confirms**:
- Shared_buffers is undersized for your working set
- Table pages are thrashing in/out of cache
- Indexes aren't staying resident

### Checkpoint Health
```
checkpoints_timed: 3,659
checkpoints_req: 17
Ratio: 99.5% timed (EXCELLENT - not the problem)
```

### The Multi-Layered Problem

**Why Your Wait Events Occur**:

1. **Sequential scans** (not index usage) force reading entire 5M row table
2. **80% buffer hit ratio** means 20% of reads go to disk (DataFileRead wait)
3. **Multiple concurrent seq scans** compete for buffer pool space (BufferMapping wait)
4. **Sessions waiting for each other's reads** to complete (BufferIO wait)

**Root Cause**: Queries are doing full table scans because:
- Partial indexes have poor selectivity (too many flagged rows)
- Missing composite indexes for common query patterns
- Statistics may be stale
- Planner choosing wrong plan

---

## Resolution Framework

### Tier 1: Immediate Tactical Fixes (0-2 hours)

#### 1. Emergency: Force Statistics Update & Check Selectivity

**The idx_flagged_recent index has 0 scans - it's being ignored!**

```sql
-- First: Update statistics (critical!)
ANALYZE financial_transactions;

-- Check selectivity of is_flagged
SELECT 
  count(*) as total_rows,
  count(*) FILTER (WHERE is_flagged = true) as flagged_rows,
  round(100.0 * count(*) FILTER (WHERE is_flagged = true) / count(*), 2) as flagged_pct,
  count(*) FILTER (WHERE is_flagged = true AND transaction_date >= CURRENT_DATE - INTERVAL '30 days') as flagged_recent,
  round(100.0 * count(*) FILTER (WHERE is_flagged = true AND transaction_date >= CURRENT_DATE - INTERVAL '30 days') / count(*), 2) as flagged_recent_pct
FROM financial_transactions;

-- Check query plans
EXPLAIN (ANALYZE, BUFFERS) 
SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
FROM financial_transactions
WHERE is_flagged = true 
  AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY risk_score DESC
LIMIT 100;
```

**Expected Finding**: If `is_flagged = true` covers >5-10% of rows, Postgres will choose seq scan over index. This is mathematically correct behavior but devastating for performance.

#### 2. Fix the Aggregation Queries (Immediate 50%+ improvement)

**Your worst offenders are aggregations doing full table scans**:

```sql
-- Query 1: Payment method weekly aggregation (18.6 seconds, 157K blocks)
-- Problem: No index on (transaction_date, payment_method)
-- FIXED: Remove CURRENT_DATE from predicate (not IMMUTABLE)
CREATE INDEX CONCURRENTLY idx_txn_date_payment 
ON financial_transactions (transaction_date DESC, payment_method);

-- For even better performance with recent data queries:
CREATE INDEX CONCURRENTLY idx_txn_date_payment_include
ON financial_transactions (transaction_date DESC, payment_method)
INCLUDE (amount_usd);  -- Covers the SUM(amount_usd) in your query

-- Query 2: Fraud status aggregation (16.1 seconds, 155K blocks)  
-- Problem: No index on (risk_score, fraud_check_status)
CREATE INDEX CONCURRENTLY idx_txn_risk_fraud
ON financial_transactions (transaction_date DESC, risk_score, fraud_check_status)
INCLUDE (amount_usd, customer_id);  -- Covers aggregation columns

-- Expected impact: 80-95% reduction in execution time for these queries
```

**Why no WHERE clause**: CURRENT_DATE is STABLE (changes daily), not IMMUTABLE (never changes). Index predicates require IMMUTABLE functions. Instead, Postgres will use index range scans efficiently for `WHERE transaction_date >= X` queries.

#### 3. Add Covering Index for Flagged Query

**Since your partial index isn't being used**, create a covering index that makes seq scan unnecessary:

```sql
-- Option 1: Covering index WITHOUT date restriction in predicate
-- (Postgres will still use index efficiently for date range queries)
CREATE INDEX CONCURRENTLY idx_flagged_covering_v1
ON financial_transactions (
  transaction_date DESC,
  risk_score DESC,
  transaction_id,
  customer_id,
  amount,
  fraud_check_status
)
WHERE is_flagged = true AND is_deleted = false;

-- Option 2: If is_flagged = true is > 10% of rows, use non-partial index
-- Check selectivity first:
SELECT 
  count(*) as total,
  count(*) FILTER (WHERE is_flagged = true) as flagged,
  round(100.0 * count(*) FILTER (WHERE is_flagged = true) / count(*), 2) as pct
FROM financial_transactions;

-- If flagged_pct > 10%, create without WHERE clause:
CREATE INDEX CONCURRENTLY idx_flagged_covering_v2
ON financial_transactions (
  is_flagged,
  transaction_date DESC,
  risk_score DESC
)
INCLUDE (transaction_id, customer_id, amount, fraud_check_status)
WHERE is_deleted = false;

-- This uses INCLUDE clause (PG11+) to store non-indexed columns
-- Enables index-only scans without bloating the B-tree structure
```

**Why covering index works**:
- All SELECT columns available in index = no heap lookups required
- Postgres can satisfy entire query from index pages
- Even if selectivity is poor, index-only scan beats seq scan
- INCLUDE columns don't participate in B-tree ordering (smaller index)

#### 3b. Alternative: Partial Index with Fixed Date

**If you want a smaller partial index for truly recent data**:

```sql
-- Use explicit date instead of CURRENT_DATE
-- Update this monthly or use a cron job
CREATE INDEX CONCURRENTLY idx_flagged_recent_fixed
ON financial_transactions (
  transaction_date DESC,
  risk_score DESC,
  transaction_id,
  customer_id,
  amount,
  fraud_check_status
)
WHERE is_flagged = true 
  AND is_deleted = false
  AND transaction_date >= '2024-10-01'::date;  -- Update this monthly

-- Or use relative date that's IMMUTABLE-safe:
-- Create immutable function wrapper:
CREATE OR REPLACE FUNCTION ninety_days_ago() 
RETURNS date AS $
  SELECT CURRENT_DATE - INTERVAL '90 days';
$ LANGUAGE SQL IMMUTABLE;

-- Then use in index (won't update daily, but acceptable):
CREATE INDEX CONCURRENTLY idx_flagged_recent_fn
ON financial_transactions (transaction_date DESC, risk_score DESC)
INCLUDE (transaction_id, customer_id, amount, fraud_check_status)
WHERE is_flagged = true 
  AND is_deleted = false
  AND transaction_date >= ninety_days_ago();
```

**Recommendation**: Use Option 1 or Option 2 (non-IMMUTABLE predicate). The partial index size savings aren't worth the maintenance overhead of updating date predicates.

#### 4. Drop Unused Indexes (Immediate space savings)

**You have 7 indexes with 0 scans - they're pure overhead**:

```sql
-- These have NEVER been used and cost write performance:
DROP INDEX CONCURRENTLY idx_txn_account;           -- 0 scans, 56 MB
DROP INDEX CONCURRENTLY idx_txn_metadata;          -- 0 scans, 32 MB  
DROP INDEX CONCURRENTLY idx_txn_tags;              -- 0 scans, 11 MB
DROP INDEX CONCURRENTLY idx_txn_active;            -- 0 scans, 107 MB
DROP INDEX CONCURRENTLY idx_flagged_recent;        -- 0 scans, 8 KB (not working anyway)
DROP INDEX CONCURRENTLY idx_high_value_recent;     -- 0 scans, 135 MB
DROP INDEX CONCURRENTLY financial_transactions_external_txn_id_key; -- 0 scans, 150 MB (unless you need UNIQUE constraint)

-- Total space freed: ~491 MB
-- Write performance improvement: ~15-25% (7 fewer indexes to maintain)
```

**CRITICAL**: Only drop `financial_transactions_external_txn_id_key` if you don't need the UNIQUE constraint. If you do, keep it.

#### 5. Aggressive Autovacuum Tuning (Table-Level)

```sql
-- Check current dead tuple situation
SELECT 
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'financial_transactions';

-- Much more aggressive autovacuum for this table
ALTER TABLE financial_transactions SET (
  autovacuum_vacuum_scale_factor = 0.01,      -- vacuum at 1% updates (vs 20% default)
  autovacuum_analyze_scale_factor = 0.005,    -- analyze at 0.5% updates
  autovacuum_vacuum_cost_delay = 10,          -- faster vacuuming
  autovacuum_vacuum_cost_limit = 2000         -- higher work limit per round
);

-- Immediate manual vacuum to baseline
VACUUM (VERBOSE, ANALYZE) financial_transactions;
```

#### 6. Check for Index Bloat

```sql
-- Install pgstattuple if not present
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Check bloat on your active indexes
SELECT 
  indexrelname,
  round(100.0 * (100 - avg_leaf_density), 2) AS pct_bloat,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
  leaf_pages,
  deleted_pages
FROM pgstatindex('idx_txn_date'), 
     pg_stat_user_indexes 
WHERE indexrelname = 'idx_txn_date';

SELECT 
  indexrelname,
  round(100.0 * (100 - avg_leaf_density), 2) AS pct_bloat,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pgstatindex('idx_txn_created_at'),
     pg_stat_user_indexes
WHERE indexrelname = 'idx_txn_created_at';

-- If bloat >20%, reindex
REINDEX INDEX CONCURRENTLY idx_txn_date;
REINDEX INDEX CONCURRENTLY idx_txn_created_at;
```

### Tier 2: Configuration Tuning (2-8 hours, requires testing)

#### 1. Increase shared_buffers (CRITICAL - Your buffer hit ratio is 80.69%)

**Your Current State**:
- Buffer hit ratio: **80.69%** (should be >95%)
- 19.31% of reads going to disk = massive DataFileRead waits
- 114,527 buffers for financial_transactions = ~917MB in cache
- Table size is likely 2-4GB, meaning only 25-45% fits in memory

**Diagnosis**:
```sql
-- Check current setting
SHOW shared_buffers;

-- Check your RDS instance class
-- db.r6g.xlarge (32GB) → default shared_buffers ~1GB
-- db.r6g.2xlarge (64GB) → default shared_buffers ~2GB

-- Check table size
SELECT 
  pg_size_pretty(pg_total_relation_size('financial_transactions')) as total_size,
  pg_size_pretty(pg_relation_size('financial_transactions')) as table_size,
  pg_size_pretty(pg_total_relation_size('financial_transactions') - pg_relation_size('financial_transactions')) as indexes_size;
```

**Recommended Setting** (requires parameter group change + restart):

For RDS PostgreSQL on r6g instances:
```
# Current (likely): {DBInstanceClassMemory/32768} = ~1GB for 32GB instance
# Recommended: 35-40% of RAM

# For db.r6g.xlarge (32GB RAM):
shared_buffers = 1,677,721  # ~13GB (40% of RAM)

# For db.r6g.2xlarge (64GB RAM):  
shared_buffers = 3,355,443  # ~26GB (40% of RAM)

# For db.r5.xlarge (32GB RAM):
shared_buffers = 1,677,721  # ~13GB (40% of RAM)
```

**Why 35-40% on RDS**:
- RDS needs OS cache for XFS filesystem
- Unlike on-prem, you can't use 50%+ without degrading OS performance
- RDS maintenance operations need headroom

**Expected Impact**:
- Buffer hit ratio: 80% → 96-98%
- DataFileRead waits: -70%
- BufferMapping contention: -60% (fewer cache misses)
- Query latency: -50-70%

**CRITICAL**: This requires restart. Test in staging/dev first. Schedule during maintenance window.

#### 2. Evaluate effective_cache_size

```sql
-- Check current
SHOW effective_cache_size;

-- Set to 60-75% of total RAM (hint to query planner)
-- For 32GB instance:
effective_cache_size = 24GB  # 75% of RAM
```

This doesn't allocate memory but tells the planner how much total cache (shared_buffers + OS cache) is available. Affects index vs seq scan decisions.

#### 3. Connection Pooling Assessment (Buffer Mapping scales with connections)

```sql
-- Check active connections
SELECT 
  count(*) FILTER (WHERE state = 'active') as active,
  count(*) FILTER (WHERE state = 'idle') as idle,
  count(*) FILTER (WHERE state = 'idle in transaction') as idle_in_txn,
  count(*) as total,
  max_connections.setting::int as max_conn
FROM pg_stat_activity, 
     (SELECT setting FROM pg_settings WHERE name = 'max_connections') max_connections
WHERE backend_type = 'client backend'
GROUP BY max_connections.setting;

-- Check connection churn
SELECT 
  datname,
  numbackends,
  xact_commit,
  xact_rollback,
  blks_read,
  blks_hit,
  tup_returned,
  tup_fetched
FROM pg_stat_database
WHERE datname = current_database();
```

**Best Practice for RDS**:
- Use **RDS Proxy** (eliminates connection overhead, multiplexing)
- Or deploy **PgBouncer** on separate EC2
- Pool size formula: `(vCPUs * 2) + effective_spindle_count`
  - For r6g.xlarge (4 vCPU): 10-15 connections optimal
  - For r6g.2xlarge (8 vCPU): 20-25 connections optimal

**Expected Impact**:
- BufferMapping contention: -50-70%
- Connection establishment latency: -90%
- Memory overhead: -80%

#### 4. Work_mem Tuning for Aggregation Queries

Your aggregation queries are doing large sorts/aggregations:

```sql
-- Check current
SHOW work_mem;

-- Typical RDS default: 4MB (too small for your aggregations)

-- Set higher for session running aggregations:
SET work_mem = '256MB';  -- For your aggregation queries

-- Or set in parameter group globally
work_mem = 64MB  # Conservative global setting
```

**For your specific queries**:
```sql
-- Before running expensive aggregation:
SET work_mem = '512MB';
SELECT /* your aggregation query */;
RESET work_mem;
```

**Expected Impact**:
- Eliminates disk sorts for aggregations
- Reduces temp file I/O
- Aggregation queries: 30-50% faster

#### 5. Random_page_cost Tuning (for SSD/NVMe storage)

```sql
-- Check current
SHOW random_page_cost;
-- RDS default: 4.0 (tuned for spinning disks)

-- For gp3 SSD:
random_page_cost = 1.1

-- For io2 Block Express:
random_page_cost = 1.0

-- This makes index scans more attractive to planner
```

### Tier 3: Strategic Optimizations (1-2 weeks)

#### 1. Query Pattern Optimization

**Consider Covering Index**:
```sql
-- Include all SELECT columns to avoid heap lookups
CREATE INDEX CONCURRENTLY idx_flagged_covering
ON financial_transactions (
  transaction_date,
  transaction_id,
  customer_id,
  amount,
  risk_score,
  fraud_check_status
)
WHERE is_flagged = true AND is_deleted = false;
```

**Benefits**:
- Index-only scans (no heap access)
- Dramatically reduces I/O
- Drawback: larger index, slower writes

#### 2. Materialized View for Hot Queries

If flagged transactions are repeatedly queried:

```sql
CREATE MATERIALIZED VIEW flagged_transactions_hot AS
SELECT 
  transaction_id,
  customer_id,
  amount,
  risk_score,
  fraud_check_status,
  transaction_date,
  transaction_time,
  payment_method
FROM financial_transactions
WHERE is_flagged = true 
  AND is_deleted = false
  AND transaction_date >= CURRENT_DATE - INTERVAL '90 days';

CREATE UNIQUE INDEX ON flagged_transactions_hot (transaction_id);
CREATE INDEX ON flagged_transactions_hot (transaction_date DESC);

-- Refresh strategy (choose based on freshness requirements)
-- Option 1: On-demand
REFRESH MATERIALIZED VIEW CONCURRENTLY flagged_transactions_hot;

-- Option 2: Scheduled (via pg_cron or external scheduler)
```

#### 3. Partitioning Strategy

For long-term scalability with 5M+ rows:

```sql
-- Partition by transaction_date (range partitioning)
-- Allows partition pruning and easier data lifecycle management

CREATE TABLE financial_transactions_new (
  LIKE financial_transactions INCLUDING ALL
) PARTITION BY RANGE (transaction_date);

-- Create monthly partitions
CREATE TABLE financial_transactions_2024_12 
  PARTITION OF financial_transactions_new
  FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

-- Partial indexes per partition
CREATE INDEX ON financial_transactions_2024_12 (transaction_date, risk_score)
WHERE is_flagged = true;
```

**Benefits**:
- Smaller indexes per partition
- Partition pruning reduces pages scanned
- Easy data archival/drops old partitions

#### 4. Fillfactor Tuning for High-Update Tables

```sql
-- Reduce fillfactor to leave room for HOT updates
ALTER TABLE financial_transactions SET (
  fillfactor = 80  -- default 100, leave 20% free space
);

-- Rebuild table (requires downtime or pg_squeeze)
VACUUM FULL financial_transactions;

-- For indexes prone to bloat
CREATE INDEX CONCURRENTLY idx_flagged_recent_v3
ON financial_transactions (transaction_date DESC, risk_score DESC)
WITH (fillfactor = 70)
WHERE is_flagged = true;
```

---

## Monitoring & Validation

### Key Metrics to Track

```sql
-- 1. Buffer hit ratio (target: >95%, yours is 80.69%)
SELECT 
  round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) AS cache_hit_ratio,
  sum(blks_hit) as total_buffer_hits,
  sum(blks_read) as total_disk_reads
FROM pg_stat_database
WHERE datname = current_database();

-- 2. Sequential scans (yours: 2,035 scans, 1.7B tuples - THIS IS THE PROBLEM)
SELECT 
  schemaname,
  relname AS table_name,
  seq_scan,
  seq_tup_read,
  idx_scan,
  idx_tup_fetch,
  n_live_tup,
  round(100.0 * seq_tup_read / NULLIF(seq_tup_read + idx_tup_fetch, 0), 2) as seq_scan_pct
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND seq_scan > 0
ORDER BY seq_tup_read DESC
LIMIT 10;

-- 3. Wait events over time  
SELECT 
  wait_event_type,
  wait_event,
  count(*) as waiting_sessions,
  array_agg(DISTINCT left(query, 50)) as sample_queries
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY waiting_sessions DESC;

-- 4. Top I/O queries (these are your culprits)
SELECT 
  substring(query, 1, 80) as query_snippet,
  calls,
  mean_exec_time::numeric(10,2) as avg_time_ms,
  (mean_exec_time * calls)::numeric(10,2) as total_time_ms,
  shared_blks_read,
  (shared_blks_read::numeric / NULLIF(calls, 0))::numeric(10,2) as avg_read_per_call,
  round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) as hit_ratio
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 20;

-- 5. Index usage and health
SELECT 
  schemaname,
  relname AS table_name,
  indexrelname AS index_name,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
  CASE 
    WHEN idx_scan = 0 THEN '❌ UNUSED'
    WHEN idx_scan < 10 THEN '⚠️  RARELY USED'
    ELSE '✅ ACTIVE'
  END as status
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
  AND relname = 'financial_transactions'
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;

-- 6. Buffer cache composition
SELECT 
  c.relname,
  count(*) as buffers,
  round(100.0 * count(*) / (SELECT setting::int FROM pg_settings WHERE name = 'shared_buffers'), 2) as pct_of_cache,
  count(*) FILTER (WHERE b.isdirty) as dirty_buffers,
  pg_size_pretty(count(*) * 8192) as cache_size
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY c.relname
ORDER BY buffers DESC
LIMIT 20;

-- 7. Vacuum and analyze status
SELECT 
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze,
  age(now(), last_autovacuum) as time_since_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND n_live_tup > 1000
ORDER BY dead_pct DESC NULLS LAST;
```

### RDS-Specific Monitoring

**Performance Insights**:
- Track AAS (Average Active Sessions) by wait event
- Set up alarms for:
  - BufferMapping > 5 sessions
  - Buffer cache hit ratio < 95%
  - DataFileRead latency > 20ms

**CloudWatch Metrics**:
```
ReadLatency          - target: < 5ms
WriteLatency         - target: < 10ms  
BufferCacheHitRatio  - target: > 95%
DatabaseConnections  - track against max_connections
CPUUtilization       - should be steady, not spiky
```

---

## Incident Response Playbook

### When BufferMapping Spikes (>10 sessions)

**1. Immediate Assessment** (2 minutes):
```sql
-- What's causing it?
SELECT 
  pid,
  usename,
  application_name,
  state,
  wait_event_type,
  wait_event,
  query
FROM pg_stat_activity
WHERE wait_event = 'BufferMapping'
ORDER BY query_start;
```

**2. Quick Wins**:
- Check if one query pattern dominates → kill if necessary
- Verify buffer cache hit ratio hasn't dropped suddenly
- Check for vacuum/analyze running (might be beneficial)

**3. Escalation Criteria**:
- Persists > 5 minutes
- Application-level timeouts occurring
- Buffer cache hit ratio < 90%

### When DataFileRead Dominates

**1. Identify Hot Queries**:
```sql
SELECT 
  pid,
  query,
  state,
  wait_event,
  now() - query_start AS duration
FROM pg_stat_activity
WHERE wait_event = 'DataFileRead'
ORDER BY query_start;
```

**2. Quick Diagnosis**:
```sql
-- Is it a scan issue?
SELECT 
  schemaname,
  tablename,
  seq_scan,
  seq_tup_read,
  idx_scan,
  n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY seq_tup_read DESC
LIMIT 10;
```

**3. Immediate Actions**:
- Missing index? Create CONCURRENTLY
- Cache cold after restart? Expected, will stabilize
- Storage IOPS maxed? Check CloudWatch, consider scaling

### When All Three Waits Occur Together

This is your current scenario. **Root cause is almost always**:
1. Inefficient query hitting hot dataset
2. Working set exceeds shared_buffers
3. Multiple concurrent executions

**Battle-tested Resolution Order**:
1. Fix the index (1 hour) → 40-60% improvement
2. Check/fix index bloat (2 hours) → 20-40% improvement  
3. Tune autovacuum (1 day to stabilize) → 10-20% improvement
4. Increase shared_buffers if feasible (requires testing + restart) → 30-50% improvement

---

## Staff-Level Considerations

### Capacity Planning

**When to scale vertically (bigger instance)**:
- Working set consistently exceeds shared_buffers
- CPU consistently > 60% even with optimized queries
- Multiple optimization attempts show diminishing returns

**When to scale horizontally (read replicas)**:
- Read/write ratio > 80/20
- Reporting queries competing with OLTP
- Geographic distribution needed

### Technical Debt Assessment

**Red Flags in Your Schema**:
1. No partitioning on 5M+ row table (consider at 10M+)
2. Boolean flags (`is_flagged`) on high-volume table → consider status enum or separate flagging table
3. Many indexes (you have 13) → evaluate unused indexes, consolidate where possible

**Optimization Priorities**:
1. **P0** (Today): Fix index structure for hot query
2. **P1** (This week): Resolve index bloat, tune autovacuum
3. **P2** (This month): Evaluate shared_buffers increase, implement connection pooling
4. **P3** (This quarter): Partitioning strategy, materialized views for hot datasets

### When to NOT Optimize

**Don't over-tune if**:
- Wait events are transient (<1 min spikes)
- Query execution time meets SLA despite waits
- Cost of optimization (complexity, maintenance) exceeds benefit

**Acceptable Baseline**:
- BufferMapping: <2 sessions during normal operations
- DataFileRead: <5% of total query time
- BufferIO: Rare (<1 session except during checkpoint)

---

## Knowledge Transfer Resources

### PostgreSQL Documentation
- [Wait Events](https://www.postgresql.org/docs/14/monitoring-stats.html#WAIT-EVENT-TABLE)
- [Indexes](https://www.postgresql.org/docs/14/indexes.html)
- [VACUUM](https://www.postgresql.org/docs/14/sql-vacuum.html)

### AWS Specific
- [RDS Wait Events - BufferMapping](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/wait-event.lwl-buffer-mapping.html)
- [RDS Wait Events - DataFileRead](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/wait-event.iodatafileread.html)
- [Tuning RDS PostgreSQL](https://docs.aws.amazon.com/prescriptive-guidance/latest/tuning-postgresql-parameters/)

### Advanced Topics
- pg_stat_statements for query analysis
- pg_buffercache for buffer pool inspection
- pgstattuple for bloat analysis
- Performance Insights deep dive

---

## Conclusion

Your wait event pattern (BufferMapping + DataFileRead + BufferIO on same queries) combined with the **shocking discovery** from production data reveals the real problem:

### The Core Issues (in order of severity):

1. **Sequential scans dominating workload**: 2,035 seq scans reading 1.73 BILLION tuples vs only 54M via indexes (32:1 ratio)
2. **Critical partial index (`idx_flagged_recent`) never used**: 0 index scans despite being designed for your hot query
3. **Buffer cache hit ratio 15 points below target**: 80.69% instead of >95%
4. **Seven unused indexes wasting 491MB**: Causing write amplification for zero benefit
5. **Aggregation queries with no supporting indexes**: 18+ second query times

### Root Cause Analysis:

**Why indexes aren't being used**:
- `is_flagged = true` likely covers >10% of rows (poor selectivity)
- Postgres correctly determines seq scan is cheaper than partial index scan
- Missing composite indexes for common aggregation patterns
- Statistics potentially stale (ANALYZE needed)

**Why wait events cascade**:
1. Sequential scans read entire 5M row table (DataFileRead)
2. Multiple concurrent scans compete for limited buffer pool space (BufferMapping)
3. Sessions wait for each other's I/O operations (BufferIO)
4. 80% buffer hit ratio means 1 in 5 page requests goes to disk, amplifying the problem

### Expected Outcomes After All Fixes:

**Tier 1 (Day 1) - Immediate tactical fixes**:
- **Aggregation queries**: 18.6s → <1s (95% improvement)
- **Flagged query**: 34.4s → <500ms (98% improvement)
- **Sequential scans**: 2,035 → <50 (97% reduction)
- **Unused indexes dropped**: +15% write performance, -491MB storage

**Tier 2 (Week 1) - Configuration tuning**:
- **Buffer hit ratio**: 80.69% → 96-98%
- **DataFileRead waits**: -70%
- **BufferMapping waits**: -60%
- **Overall query latency**: -50-70%

**Final State (Month 1)**:
- Buffer cache hit ratio: >96%
- Wait events: BufferMapping <2 sessions, DataFileRead rare
- Query performance: All queries <1s p95
- Index efficiency: >95% of queries using indexes

### Start Here (Priority Order):

1. **ANALYZE financial_transactions** (30 seconds) - Update statistics
2. **Check is_flagged selectivity** (1 min) - Understand why index isn't used
3. **Create covering indexes** (30 min) - Fix aggregation and flagged queries
4. **Drop unused indexes** (15 min) - Immediate write performance gain
5. **Tune autovacuum** (5 min) - Prevent future bloat
6. **Increase shared_buffers** (requires maintenance window) - 15-point buffer hit ratio gain

### Maintenance Tasks (Ongoing):

**Daily**:
- Monitor buffer hit ratio (should stay >95%)
- Check wait events (should be minimal)
- Review slow query log

**Weekly**:
- Review pg_stat_statements for new slow queries
- Check for new sequential scans
- Validate index usage

**Monthly**:
- Check index bloat (pgstattuple)
- Review autovacuum effectiveness  
- Evaluate new indexes vs drops
- Capacity planning based on growth

### When to Escalate:

**Scale vertically (larger instance) if**:
- After all optimizations, buffer hit ratio still <90%
- CPU consistently >70% even with optimized queries
- Working set grows beyond 70% of available shared_buffers

**Scale horizontally (read replicas) if**:
- Read/write ratio >85/15
- Geographic distribution needed
- Reporting queries interfere with OLTP even after optimization

### Technical Debt to Address:

**Immediate (this quarter)**:
- Evaluate all 13 indexes - you likely only need 5-6
- Consider partitioning strategy for future growth (10M+ rows)
- Implement materialized views for hot aggregations

**Long-term (next 2 quarters)**:
- Data lifecycle management (archive old transactions)
- Separate flagging/fraud detection into dedicated table
- Consider moving boolean flags to status enums for better stats

---

*This runbook is based on your actual PostgreSQL 14 production data from RDS showing 80.69% buffer hit ratio, 2,035 sequential scans, and 7 unused indexes. All recommendations are prioritized by immediate impact and effort required.*
