# Platform DBRE Performance Investigation Methodology

## The Complete Framework: From Symptoms to Resolution

### Mental Model

```
Symptoms → System Health → Query Execution → Statistics → Physical Layout → Resolution
    ↓           ↓              ↓                ↓              ↓              ↓
  Waits    Buffer Cache    EXPLAIN Plan      pg_stats      Indexes       Fix & Verify
```

---

## Phase 1: System-Level Health Assessment 

**Goal**: Understand if this is a systemic issue or query-specific problem.

### 1.1 Wait Events Analysis

```sql
-- Current wait events snapshot
SELECT * FROM dbre_wait_analysis ORDER BY waiting_sessions DESC;

-- Or minimal version:
SELECT 
  wait_event_type,
  wait_event,
  count(*) as sessions,
  max(EXTRACT(EPOCH FROM (now() - query_start))) as max_wait_sec
FROM pg_stat_activity
WHERE wait_event IS NOT NULL AND state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

**What to look for:**
- **BufferMapping + DataFileRead + BufferIO together** → Cache thrashing, check buffer hit ratio
- **ClientRead** → Application not consuming results fast enough
- **WALWrite** → Write-heavy workload, check wal_buffers
- **Lock-related waits** → Blocking queries, check pg_locks

**Decision Tree:**
- High wait counts (>10 sessions) → **Systemic issue**, continue to Phase 1.2
- Moderate waits (2-5 sessions) on same query → **Query-specific**, skip to Phase 2
- Transient waits (<1s, <2 sessions) → **Normal**, monitor only

### 1.2 Buffer Cache Hit Ratio

```sql
SELECT 
  round(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) as hit_ratio,
  sum(blks_read) as disk_reads,
  pg_size_pretty(sum(blks_read) * 8192) as data_from_disk
FROM pg_stat_database 
WHERE datname = current_database();
```

**Targets:**
- OLTP workloads: **>95%**
- Analytics workloads: **>90%**
- Below target → Consider increasing `shared_buffers`

### 1.3 Sequential Scan Ratio

```sql
SELECT 
  schemaname,
  relname,
  seq_scan,
  seq_tup_read,
  idx_scan,
  idx_tup_fetch,
  round(100.0 * seq_tup_read / NULLIF(seq_tup_read + idx_tup_fetch, 0), 1) as seq_pct
FROM pg_stat_user_tables
WHERE seq_scan > 100
ORDER BY seq_tup_read DESC
LIMIT 10;
```

**Red flags:**
- `seq_pct > 30%` on OLTP tables → Missing or unused indexes
- `seq_tup_read` >> `n_live_tup` → Same table scanned repeatedly

### 1.4 Connection Pool Health

```sql
SELECT 
  state,
  count(*) as count,
  max(now() - state_change) as max_duration
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY state;
```

**Watch for:**
- `idle in transaction` > 5 minutes → Application not closing transactions
- `active` > 80% of `max_connections` → Need connection pooling

---

## Phase 2: Query-Level Investigation (10-20 minutes)

**Goal**: Understand why a specific query is slow.

### 2.1 Identify Slow Queries

```sql
-- Top queries by total time
SELECT 
  substring(query, 1, 80) as query,
  calls,
  round(mean_exec_time::numeric, 2) as avg_ms,
  round((mean_exec_time * calls)::numeric, 2) as total_time_ms,
  round(100.0 * (mean_exec_time * calls) / sum(mean_exec_time * calls) OVER (), 2) as pct_total
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY mean_exec_time * calls DESC
LIMIT 20;
```

**Focus on:**
- Queries consuming >5% of total database time
- Queries with `avg_ms > 100ms` for OLTP
- High `calls` with moderate `avg_ms` (death by a thousand cuts)

### 2.2 EXPLAIN ANALYZE (The Core Skill)

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING, VERBOSE)
<your_slow_query>;
```

**Reading EXPLAIN Plans: Bottom to Top**

#### Step 1: Find the Actual Execution Time
```
Planning Time: 0.5 ms
Execution Time: 5234.2 ms  ← START HERE
```

#### Step 2: Read Bottom-to-Top, Look for:

**Cost Estimation vs Reality:**
```
Seq Scan on financial_transactions
  (cost=0.00..123456.00 rows=5000000 width=100)  ← Planner estimate
  (actual time=0.123..5234.156 rows=14200 loops=1) ← Reality
  
🚨 RED FLAG: Estimated 5M rows, actually returned 14K
```

**Buffer Statistics:**
```
Buffers: shared hit=8912 read=45234 dirtied=0 written=0
         ^^^^^^^^^^^  ^^^^^^^^
         In cache     From disk
```
- `read` >> `hit` → Poor cache utilization
- `read` in inner loop → Nested loop reading from disk repeatedly

**Node Types and What They Mean:**

1. **Seq Scan** → Reading entire table
   - Good: Small tables (<10K rows), full aggregations
   - Bad: Large tables with selective WHERE clause

2. **Index Scan** → Reading index + heap lookups
   - Good: High selectivity (<5% of rows)
   - Bad: Low selectivity (heap lookup overhead)

3. **Index Only Scan** → Reading only index (best!)
   - Requires: VACUUM to set visibility map
   - Check: `Heap Fetches: 0` (if >0, not truly index-only)

4. **Bitmap Index Scan** → Building bitmap of matching rows
   - Good: Moderate selectivity (5-25% of rows)
   - Combines multiple indexes efficiently

5. **Nested Loop** → For each row in outer, scan inner
   - Good: Outer small, inner indexed
   - Bad: Outer large, causes multiplication of I/O

6. **Hash Join** → Build hash table, probe it
   - Good: Large equijoins
   - Memory: Check `work_mem` if "batches" > 1

7. **Merge Join** → Sorted inputs, merge them
   - Good: Already sorted data, equality joins
   - Rare: Usually Hash Join is chosen instead

#### Step 3: Identify the Bottleneck Node

Look for the node with:
- Highest `actual time` difference from its child
- Highest `Buffers: read` count
- Largest discrepancy between estimated and actual rows

### 2.3 Common EXPLAIN Anti-Patterns

**Pattern 1: Wrong Cardinality Estimate**
```
Hash Join (cost=... rows=100 ...)      ← Estimated 100
  (actual rows=100000 loops=1)         ← Actually 100K
```
**Cause:** Stale or missing statistics
**Fix:** `ANALYZE table;` or `CREATE STATISTICS` for correlated columns

**Pattern 2: Missing Index**
```
Seq Scan on orders (actual rows=12 ...)
  Filter: (customer_id = 12345)
  Rows Removed by Filter: 4999988      ← Scanned 5M to find 12!
```
**Cause:** No index on `customer_id`
**Fix:** `CREATE INDEX ON orders(customer_id);`

**Pattern 3: Index Present But Not Used**
```
Seq Scan on transactions (rows=14200)
  Filter: (is_flagged = true)
  -- Index idx_flagged exists but unused!
```
**Cause:** Multiple possibilities (Phase 3 investigation)

**Pattern 4: Nested Loop of Death**
```
Nested Loop (rows=1000000)
  -> Seq Scan on table_a (rows=1000)
  -> Index Scan on table_b (rows=1000)  ← Runs 1000 times!
     Buffers: shared read=1000000       ← Million disk reads
```
**Cause:** JOIN on wrong columns or missing index
**Fix:** Check JOIN conditions, add indexes, or force Hash Join

**Pattern 5: Work_mem Too Small**
```
Sort (actual rows=500000)
  Sort Method: external merge  Disk: 45678kB  ← Spilled to disk!
```
**Cause:** `work_mem` insufficient
**Fix:** Increase `work_mem` for session or globally

---

## Phase 3: Statistics Investigation (5-10 minutes)

**When to investigate statistics:**
- EXPLAIN shows large estimate vs actual discrepancy
- Index exists but not used
- Wrong join type chosen (Nested Loop vs Hash Join)

### 3.1 Check Statistics Freshness

```sql
SELECT * FROM dbre_stats_health WHERE tablename = 'your_table';
```

**Red flags:**
- `n_mod_since_analyze > 20%` → Stale stats
- `time_since_analyze > 7 days` → Old stats
- `dead_tuple_pct > 10%` → Bloat affecting stats

### 3.2 Analyze Column Statistics

```sql
SELECT * FROM dbre_analyze_column_for_query('schema', 'table', 'column');
```

**What to check:**

**Distinct Values:**
- n_distinct = 1 → No selectivity, remove from indexes
- n_distinct = 2 (boolean) → Good for partial index if skewed
- n_distinct = -1 → Postgres thinks column is unique
- n_distinct = -0.5 → Postgres thinks 50% distinct (common for estimates)

**Null Fraction:**
- null_frac > 0.5 → Consider partial index `WHERE col IS NOT NULL`

**Correlation:**
- |correlation| > 0.9 → Physical order matches logical order
  - Index scans very efficient (sequential I/O)
- |correlation| < 0.3 → Physical order random
  - Index scans cause random I/O
  - Bitmap scans preferred
  
**Most Common Value (MCV):**
- If query value is in MCV → Estimate accurate
- If query value not in MCV → Estimate from histogram (less accurate)
- MCV frequency > 0.5 → Heavily skewed
  - For common value: Seq scan might be correct!
  - For rare value: Separate partial index

### 3.3 Multi-Column Statistics

**When columns are correlated:**
```sql
-- Example: city + state, year + month, is_flagged + date
CREATE STATISTICS stat_name ON col1, col2 FROM table;
ANALYZE table;

-- Verify
SELECT * FROM pg_stats_ext WHERE tablename = 'table';
```

**Planner assumes independence** by default:
- Selectivity(A AND B) = Selectivity(A) × Selectivity(B)
- If A and B are correlated, this estimate is wrong!

---

## Phase 4: Physical Layout Investigation 

### 4.1 Index Analysis

```sql
SELECT * FROM dbre_index_stats_matcher WHERE tablename = 'your_table';
```

**Index Health Checks:**

1. **Unused Indexes (idx_scan = 0)**
   - Verify with: Check if queries should use it
   - Action: Drop after confirming unused in all queries

2. **Low Selectivity Leading Column**
   - `leading_col_distinct = 2` on 5M row table → 2.5M rows per value
   - Action: Reorder index columns or use partial index

3. **Poor Correlation**
   - `leading_col_correlation < 0.3` → Random I/O
   - Action: Consider CLUSTER or accept Bitmap Scan

4. **Index Bloat**
   ```sql
   SELECT 
     indexrelname,
     pg_size_pretty(pg_relation_size(indexrelid)) as size,
     round(100 * (pg_relation_size(indexrelid)::float / 
       NULLIF(pg_relation_size(relid), 0)), 1) as pct_of_table
   FROM pg_stat_user_indexes
   WHERE relname = 'your_table';
   ```
   - Index > 50% of table size → Check bloat with pgstattuple
   - Action: `REINDEX CONCURRENTLY`

### 4.2 Table Bloat

```sql
SELECT 
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) as bloat_pct,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'your_table';
```

**Actions:**
- bloat_pct > 20% → `VACUUM table;`
- bloat_pct > 50% → `VACUUM FULL table;` (requires lock!) or pg_repack

### 4.3 Table Partitioning Assessment

**Consider partitioning when:**
- Table > 10M rows and growing
- Queries frequently filter on date/range column
- Old data can be archived/dropped

**Benefits:**
- Partition pruning eliminates partitions from scans
- Easier data lifecycle management
- Better statistics per partition

---

## Phase 5: Resolution & Verification (30-60 minutes)

### 5.1 Resolution Decision Tree

**If statistics are stale:**
```sql
ANALYZE table;
-- Verify: Re-run EXPLAIN, check if plan changed
```

**If index missing:**
```sql
CREATE INDEX CONCURRENTLY idx_name ON table(columns);
-- Verify: Check pg_stat_user_indexes after queries run
```

**If index exists but unused:**

**Reason 1: Poor selectivity**
```sql
-- Check selectivity
SELECT count(*) FILTER (WHERE condition) * 100.0 / count(*) FROM table;
-- If > 5-10%, seq scan might be correct!
-- Solution: Accept seq scan OR create covering index for index-only scan
```

**Reason 2: Wrong column order**
```sql
-- Current index: (col_a, col_b)
-- Query filters: WHERE col_b = X
-- Fix: CREATE INDEX ON table(col_b, col_a);
```

**Reason 3: Function/expression in query**
```sql
-- Query: WHERE LOWER(email) = 'test@example.com'
-- Fix: CREATE INDEX ON table(LOWER(email));
```

**Reason 4: Type mismatch**
```sql
-- Column: transaction_id (bigint)
-- Query: WHERE transaction_id = '12345'  (text)
-- Fix: Change query to: WHERE transaction_id = 12345
```

**Reason 5: OR condition**
```sql
-- Query: WHERE col_a = X OR col_b = Y
-- Indexes on col_a and col_b separately won't help!
-- Fix: UNION of two queries or GIN/GiST index
```

**If shared_buffers too small:**
```sql
-- Check current and recommended
SHOW shared_buffers;
-- For RDS: modify parameter group, requires restart
-- Target: 25-40% of RAM for dedicated DB server
```

### 5.2 Verification Loop

**After making changes:**

1. **Reset statistics** (optional, for clean baseline):
   ```sql
   SELECT pg_stat_statements_reset();
   ```

2. **Run the query multiple times** (warm cache):
   ```sql
   -- First run: cold cache
   SELECT ...; 
   -- Second run: warm cache (should be faster)
   SELECT ...;
   -- Third run: verify consistency
   SELECT ...;
   ```

3. **Check EXPLAIN plan changed**:
   ```sql
   EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
   -- Look for: Index Scan vs Seq Scan, buffer hit vs read
   ```

4. **Monitor wait events**:
   ```sql
   SELECT * FROM dbre_wait_analysis;
   -- Should see reduction in problematic waits
   ```

5. **Verify buffer hit ratio improved**:
   ```sql
   SELECT round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2)
   FROM pg_stat_database WHERE datname = current_database();
   ```

6. **Check index is now used**:
   ```sql
   SELECT indexrelname, idx_scan, idx_tup_read
   FROM pg_stat_user_indexes
   WHERE relname = 'your_table' AND indexrelname = 'your_new_index';
   ```

---

## Phase 6: Documentation & Knowledge Sharing

### 6.1 Incident Report Template

```markdown
## Performance Incident: [Date]

### Symptom
- User reported: Slow dashboard loading
- Observed: 6+ second query times, BufferIO waits

### Investigation
1. Wait events showed BufferMapping + DataFileRead + BufferIO cascade
2. Buffer hit ratio: 80.69% (target: >95%)
3. Sequential scans: 2,159 scans reading 2B tuples
4. Query analysis showed index exists but unused

### Root Cause
- Test data had 0 flagged transactions initially
- After generating test data, statistics not updated
- Planner had stale statistics (0% selectivity)
- Chose seq scan based on outdated information

### Resolution
1. ANALYZE financial_transactions;
2. Created covering index: idx_flagged_covering
3. Verified planner now uses index
4. Query time: 34s → 100ms (99.7% improvement)

### Lessons Learned
- Always validate test data matches production patterns
- Check pg_stats before assuming planner is wrong
- Statistics freshness is critical for query performance
```

### 6.2 Runbook Updates

Add to team runbooks:
- New indexes created and why
- Configuration changes made
- Query patterns to monitor
- Thresholds for alerts

---

## Advanced Topics 

### 7.1 Query Plan Hints (PostgreSQL Extensions)

```sql
-- pg_hint_plan extension (not in vanilla Postgres)
/*+ SeqScan(table) */
/*+ IndexScan(table idx) */
/*+ Leading((a b c)) */ -- Join order
```

**When to use:** Almost never! Fix statistics instead.

### 7.2 Parallel Query Analysis

```sql
-- Check if query went parallel
EXPLAIN (ANALYZE) SELECT ...;
-- Look for: "Workers Planned: X" and "Workers Launched: Y"

-- If not parallel but should be:
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 100;
```

### 7.3 JIT Compilation

```sql
-- Check if JIT kicked in
EXPLAIN (ANALYZE, VERBOSE) SELECT ...;
-- Look for: "JIT:" section

-- If JIT overhead high:
SET jit = off;  -- For this query
```

### 7.4 Planner Cost Constants

```sql
-- Tune for your hardware (RARELY needed)
SHOW seq_page_cost;  -- Default: 1.0
SHOW random_page_cost;  -- Default: 4.0 (spinning disk)
-- For SSD: random_page_cost = 1.1

SET random_page_cost = 1.1;  -- Makes indexes more attractive
```

---

## Quick Reference: The 5-Minute Health Check

```sql
-- 1. Wait events
SELECT wait_event, count(*) FROM pg_stat_activity 
WHERE wait_event IS NOT NULL GROUP BY 1;

-- 2. Buffer hit ratio
SELECT round(100.0*sum(blks_hit)/NULLIF(sum(blks_hit+blks_read),0),2) 
FROM pg_stat_database WHERE datname=current_database();

-- 3. Top queries
SELECT substring(query,1,50), calls, mean_exec_time 
FROM pg_stat_statements ORDER BY mean_exec_time*calls DESC LIMIT 5;

-- 4. Seq scans
SELECT relname, seq_scan, seq_tup_read 
FROM pg_stat_user_tables ORDER BY seq_tup_read DESC LIMIT 5;

-- 5. Unused indexes
SELECT indexrelname, idx_scan 
FROM pg_stat_user_indexes WHERE idx_scan = 0 AND idx_tup_read = 0;
```

---

## Common Mistakes to Avoid

1. **Optimizing in the wrong order**
   - ❌ Tuning config before finding slow queries
   - ✅ Find slow queries → Fix queries → Then tune config

2. **Over-indexing**
   - ❌ Creating indexes "just in case"
   - ✅ Create indexes based on actual query patterns

3. **Ignoring statistics**
   - ❌ Assuming planner is stupid
   - ✅ Check pg_stats first, planner is usually right given its info

4. **Not testing with production-like data**
   - ❌ Testing with empty tables or toy data
   - ✅ Use pg_dump to copy prod data or generate realistic distributions

5. **Making multiple changes at once**
   - ❌ Creating 5 indexes + tuning config + running VACUUM
   - ✅ Change one thing, measure, verify, then next change

6. **Forgetting about pg_stat_statements**
   - ❌ Guessing which queries are slow
   - ✅ Let data tell you where time is spent

---

## Summary: Workflow

```
1. Wait Events (System Health)
   ↓
2. EXPLAIN ANALYZE (Query Execution) — Read BOTTOM to TOP
   ↓
3. pg_stats (Statistics Reality)
   ↓
4. Index/Table Layout (Physical Storage)
   ↓
5. Fix & Verify (Resolution)
   ↓
6. Document & Share (Knowledge Transfer)
```

**Key Insight:** Don't jump to solutions. Follow the investigation path. The problem you see (wait events) is usually a symptom, not the root cause.

**Staff-Level Behavior:**
- Work from data, not assumptions
- Document as you investigate
- Explain your reasoning to team
- Build reusable diagnostic tools
- Share knowledge through runbooks
- Think about prevention, not just fixes
