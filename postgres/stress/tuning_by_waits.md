# Reading Wait Events 

## Your Current Situation Analysis

```
26 waiting sessions | BufferIO top wait | 79.64% buffer hit ratio
```

Let me teach you how to **instantly** recognize patterns and know what to investigate.

---

## Part 1: Wait Event Pattern Recognition

### The Wait Event "Smell Test" 

When you see wait events, ask these questions in order:

#### Question 1: How Many Sessions Are Waiting?
```
< 3 sessions   = Normal operations, transient waits (✅ ignore)
3-10 sessions  = Moderate contention (⚡ investigate if persistent)
10+ sessions   = Severe problem (🚨 immediate action)
26 sessions    = CRISIS MODE (🚨🚨🚨 your case!)
```

#### Question 2: Are Waits Transient or Persistent?
```
Watch for 30 seconds:
- Waits appear/disappear → Transient (query burst)
- Same count for 30s+    → Persistent (systemic issue)

Your case: 26 sessions stable across snapshots → PERSISTENT PROBLEM
```

#### Question 3: Single Wait Type or Multiple?
```
1 wait type    = Specific bottleneck (focused fix)
2-3 wait types = Related cascade (need to find root)
5+ wait types  = System overwhelmed (scale up)

Your case: 3 distinct waits, BufferIO dominant → CASCADE PATTERN
```

---

## Part 2: Wait Event Decoder Ring

### Your Case: BufferIO Dominant with 79.64% Cache Hit

**What BufferIO Actually Means:**
```
Session A: "I need block 12345"
Session A: *checks buffer pool* "Not there, I'll read from disk"
Session A: *locks buffer slot* "Reading now..."

Session B: "I need block 12345 too"
Session B: "Someone is already reading it, I'll wait..."
            ↑
        BufferIO wait (waiting for Session A's I/O to complete)
```

### The Diagnostic Tree for BufferIO

```
BufferIO (26 sessions waiting)
    ↓
Check: Buffer Hit Ratio
    ↓
├─ >95% → Hot page contention (many sessions want SAME blocks)
│         Action: Check what queries are running
│         Tool: SELECT * FROM dbre_waiting_sessions_detail;
│
└─ <95% → Cache thrashing (working set doesn't fit in memory)
          ↓ Your case: 79.64% (15 points below target!)
          This means: 20% of reads going to disk
          
          Check: What's consuming shared_buffers?
          ↓
          SELECT * FROM pg_buffercache
          WHERE relname = 'financial_transactions'
          
          Check: Sequential scans?
          ↓
          SELECT seq_scan, seq_tup_read FROM pg_stat_user_tables
          WHERE relname = 'financial_transactions'
          
          Root Cause Options:
          1. Sequential scans evicting useful pages
          2. Working set > shared_buffers size
          3. Indexes not being used
```

---

## Part 3: The Complete Wait Event Field Guide

### Category 1: I/O Waits (Reading from Disk)

#### **DataFileRead** (The Primary Wait)
```
Meaning: Session is reading a data page from disk
Root Causes:
  - Page not in buffer cache (cache miss)
  - Sequential scan of large table
  - Index scan on poorly cached table
  
Diagnostic Path:
  1. Check buffer hit ratio
     → <95% = cache too small or thrashing
  2. Check which table/query
     → SELECT * FROM dbre_waiting_sessions_detail WHERE wait_event = 'DataFileRead'
  3. Check if sequential scans
     → SELECT seq_scan, seq_tup_read FROM pg_stat_user_tables ORDER BY seq_tup_read DESC
  
Resolution:
  - High seq scans → Add indexes
  - Low cache hit → Increase shared_buffers
  - Large working set → Partition tables or scale vertically
```

#### **BufferIO** (The Cascade Wait)
```
Meaning: Waiting for ANOTHER session's I/O to complete
This is ALWAYS a secondary wait caused by DataFileRead

Pattern Recognition:
  BufferIO + DataFileRead together → Many sessions reading same uncached pages
  BufferIO alone (rare)           → Checkpoint-related I/O

Diagnostic Path:
  1. Find the DataFileRead sessions (they're causing BufferIO)
  2. Fix DataFileRead root cause
  3. BufferIO will automatically resolve
  
Your Case:
  26 BufferIO waits + 79% cache hit = Classic cache thrashing
  Many sessions → Same query → Pages not in cache → Waiting on each other
```

#### **DataFileExtend**
```
Meaning: Extending data file (adding new blocks to table)
Root Causes:
  - Heavy INSERT/UPDATE workload
  - Table growing rapidly
  
Resolution:
  - Usually transient, acceptable during bulk loads
  - If persistent: Pre-allocate space or check storage IOPS
```

### Category 2: Lock Waits (Blocking)

#### **Lock (relation, tuple, etc.)**
```
Meaning: Waiting for another session to release a lock
Root Causes:
  - Long-running transaction holding locks
  - Explicit LOCK TABLE statement
  - FK constraint check
  
Diagnostic:
  SELECT * FROM pg_locks WHERE NOT granted;
  -- Find blocking query:
  SELECT blocking_activity.query 
  FROM pg_locks blocked_locks
  JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
  WHERE NOT blocked_locks.granted
  
Resolution:
  - Terminate blocking session (if appropriate)
  - Optimize long transaction
  - Redesign locking strategy
```

#### **LWLock - BufferMapping**
```
Meaning: Waiting to acquire lightweight lock on buffer pool hash table
Root Causes:
  - Too many sessions searching buffer pool simultaneously
  - Buffer pool hash table contention (128 partitions)
  
Pattern: Often appears WITH DataFileRead + BufferIO
  
Diagnostic Path:
  1. Check connection count
     → SELECT count(*) FROM pg_stat_activity WHERE state = 'active'
  2. Check buffer hit ratio
     → Should be >95%
  3. Check if connection pooling in use
  
Resolution:
  - Reduce active connections (connection pooling)
  - Increase shared_buffers (reduces hash table pressure)
  - Fix queries causing excessive buffer lookups
```

### Category 3: WAL (Write-Ahead Log) Waits

#### **WALWrite**
```
Meaning: Waiting for WAL buffer to be written to disk
Root Causes:
  - Write-heavy workload
  - wal_buffers too small
  - Slow WAL disk
  
Diagnostic:
  SHOW wal_buffers;
  -- Check WAL write rate
  SELECT * FROM pg_stat_wal;
  
Resolution:
  - Increase wal_buffers (default: 16MB, try 64MB+)
  - Use faster storage for pg_wal directory
  - Batch commits if possible
```

#### **WALSync**
```
Meaning: Waiting for WAL fsync() to complete
Root Causes:
  - Slow storage
  - synchronous_commit = on (default)
  
Resolution:
  - For non-critical data: SET synchronous_commit = off
  - Use faster storage (NVMe)
  - Check storage IOPS limits (RDS)
```

### Category 4: Client Waits

#### **ClientRead**
```
Meaning: Waiting for client to consume result rows
Root Causes:
  - Application not reading results fast enough
  - Network latency
  - Client processing slow
  
This is a CLIENT problem, not a database problem!
  
Resolution:
  - Use LIMIT if fetching large result sets
  - Use cursors for pagination
  - Fix application code
```

### Category 5: Checkpoint Waits

#### **CheckpointSync**
```
Meaning: Checkpoint is syncing dirty buffers to disk
Root Causes:
  - Checkpoint happening (normal)
  - Too many dirty pages
  
Check:
  SELECT * FROM pg_stat_bgwriter;
  -- Look at checkpoints_req vs checkpoints_timed
  -- Prefer: checkpoints_timed > 95%
  
Resolution:
  - Increase max_wal_size
  - Increase checkpoint_timeout
  - Set checkpoint_completion_target = 0.9
```

---

## Part 4: Your Specific Case - The Full Story

### What Your Metrics Tell Me

```sql
SELECT * FROM dbre_wait_system_correlation;
```

**Reading the Numbers:**
```
total_waiting_sessions: 26       ← 🚨 CRISIS: 26 sessions blocked
distinct_wait_events: 3          ← Cascade: BufferIO + likely DataFileRead + BufferMapping
active_connections: 21           ← All active sessions are waiting!
idle_connections: 9              ← Some capacity left
buffer_hit_ratio: 79.64          ← 🚨 20% cache miss rate (target >95%)
checkpoints_timed: 3717          ← Checkpoints healthy (not the problem)
checkpoints_requested: 17        ← Only 0.5% requested (good)
top_wait_event: BufferIO         ← Secondary wait (something else causing it)
```

### The Full Diagnosis

**What's Actually Happening:**

1. **Root Cause**: Sequential scans or inefficient queries are reading millions of blocks
2. **Cache Thrashing**: Working set doesn't fit in shared_buffers (79% hit rate)
3. **Cascade Effect**:
   - Session 1: Reads block X from disk (DataFileRead)
   - Sessions 2-26: Want same block X, wait for Session 1 (BufferIO)
4. **Amplification**: Each cache miss blocks multiple sessions
5. **Result**: 26 sessions waiting, query latency 6+ seconds

### Step-by-Step Investigation Path

```sql
-- Step 1: Who's waiting and for how long?
SELECT 
  pid,
  wait_event,
  wait_seconds,
  left(query, 80) as query
FROM dbre_waiting_sessions_detail
ORDER BY wait_seconds DESC
LIMIT 10;

-- What you'll see:
-- Multiple sessions, same query, 6+ seconds waiting
-- This confirms: One slow query, many concurrent executions

-- Step 2: What query is causing this?
SELECT 
  query,
  calls,
  mean_exec_time,
  shared_blks_read,
  shared_blks_hit,
  round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) as hit_ratio
FROM pg_stat_statements
WHERE shared_blks_read > 10000
ORDER BY mean_exec_time * calls DESC
LIMIT 5;

-- What you'll see:
-- is_flagged query: 34 seconds, 19,840 blocks read per call, poor hit ratio
-- This confirms: Query is doing lots of I/O

-- Step 3: Why is it reading so much?
EXPLAIN (ANALYZE, BUFFERS)
SELECT ... FROM financial_transactions WHERE is_flagged = true ...;

-- What you'll likely see:
-- Seq Scan on financial_transactions (rows=5000000)
--   Buffers: shared hit=X read=45234  ← Reading from disk!
-- This confirms: Not using index, scanning entire table

-- Step 4: Why isn't index used?
SELECT * FROM dbre_index_stats_matcher 
WHERE tablename = 'financial_transactions' 
  AND indexname LIKE '%flagged%';

-- What you saw:
-- idx_flagged_covering: 0 scans (unused)
-- This confirms: Index exists but planner ignores it

-- Step 5: Why does planner ignore index?
SELECT * FROM dbre_analyze_column_for_query('public', 'financial_transactions', 'is_flagged');

-- What you saw:
-- n_distinct: 2, correlation: 1.0, stats FRESH
-- This confirms: Statistics are perfect!

-- Step 6: So why seq scan?
-- Need EXPLAIN (COSTS) to see planner's cost calculation
```

---

## Part 5: The Pattern Recognition Cheat Sheet

### Instant Diagnosis Table

| Wait Pattern | Buffer Hit | Checkpoint | Connection Count | Diagnosis |
|-------------|------------|------------|------------------|-----------|
| **BufferIO dominant** | <90% | Normal | Normal | Cache thrashing - increase shared_buffers |
| **BufferIO + DataFileRead** | <95% | Normal | Normal | Missing index or seq scans |
| **BufferMapping** | <95% | Normal | High (>50 active) | Too many connections - use pooling |
| **Lock waits** | Any | Any | Any | Check pg_locks for blocking queries |
| **WALWrite** | Any | High req% | Any | Increase wal_buffers or faster storage |
| **ClientRead** | Any | Any | Normal | Application not consuming results |
| **CheckpointSync** | Any | High req% | Any | Increase max_wal_size |

### Your Case Pattern Match

```
Wait: BufferIO dominant (26 sessions)
Buffer Hit: 79.64% (🚨 low)
Checkpoint: Normal (99.5% timed)
Connections: 21/410 active (normal)

→ MATCH: Cache thrashing pattern
→ Root cause: Sequential scans or missing index
→ Investigation: Check pg_stat_statements for high shared_blks_read
```

---

## Part 6: Building Your Investigation Muscle

### Daily Practice Routine 

**Week 1-2: Pattern Recognition**
```sql
-- Every day, run this and interpret:
SELECT * FROM dbre_wait_health_dashboard;

-- Ask yourself:
-- 1. What's the top wait event?
-- 2. How many sessions are waiting?
-- 3. Is buffer hit ratio healthy?
-- 4. What would I investigate first?

-- Then check answer:
SELECT * FROM dbre_wait_analysis;
```

**Week 3-4: Connecting Waits to Resources**
```sql
-- Practice connecting wait → resource → action:

-- Scenario 1: BufferIO + low cache hit
SELECT 
  'Wait Event' as metric, 
  'BufferIO' as value
UNION ALL
SELECT 
  'Buffer Hit Ratio',
  round(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit + blks_read), 0), 2)::text
FROM pg_stat_database
UNION ALL
SELECT 
  'Top I/O Query',
  substring(query, 1, 50)
FROM pg_stat_statements
ORDER BY shared_blks_read DESC LIMIT 1;

-- Practice: Write the investigation path before looking at data
```

**Week 5-8: Full Investigation Loops**
```sql
-- Pick a slow query each day
-- Go through complete cycle:
-- 1. Identify from pg_stat_statements
-- 2. Run EXPLAIN ANALYZE
-- 3. Check pg_stats
-- 4. Propose solution
-- 5. Implement (in test env)
-- 6. Verify improvement
```

### The "Connect the Dots" Exercise

**Given these metrics, what's happening?**

```
Scenario A:
- BufferMapping: 12 sessions
- Buffer hit ratio: 98%
- Active connections: 85
- max_connections: 100

Your diagnosis: ___________________
Investigation path: ___________________

Answer: Too many connections causing hash table contention
Path: Check connection pooling → Implement RDS Proxy
```

```
Scenario B (Your Case):
- BufferIO: 26 sessions
- Buffer hit ratio: 79.64%
- Seq scan tuples: 2B
- Index 'idx_flagged_covering': 0 scans

Your diagnosis: Index exists but not used, causing seq scans, 
                causing cache thrashing, causing BufferIO cascade
Investigation path: 
  1. Run EXPLAIN on flagged query
  2. Check why planner ignores index
  3. Fix index usage or cost model
  4. Verify BufferIO waits disappear
```

---

## Part 7: Your 90-Day Learning Path

### Month 1: Master Wait Event Recognition
- **Week 1**: Learn all wait event types (this guide)
- **Week 2**: Practice pattern matching (15 min/day)
- **Week 3**: Connect waits to pg_stat_statements
- **Week 4**: Practice full diagnosis (wait → query → plan)

**Milestone**: Can look at wait events and immediately know which resource to check

### Month 2: Master Query Analysis
- **Week 5**: EXPLAIN plan reading (bottom-to-top)
- **Week 6**: pg_stats interpretation
- **Week 7**: Index analysis and design
- **Week 8**: Practice complete investigations

**Milestone**: Can diagnose why planner makes specific decisions

### Month 3: Master Resolution
- **Week 9**: Configuration tuning (shared_buffers, work_mem, etc.)
- **Week 10**: Index optimization strategies
- **Week 11**: Advanced techniques (partitioning, materialized views)
- **Week 12**: Build team runbooks and documentation

**Milestone**: Can fix issues and prevent recurrence

---

## Part 8: Your Immediate Next Steps

### Right Now (Next 30 Minutes)

```sql
-- 1. Confirm the pattern (2 min)
SELECT * FROM dbre_wait_health_dashboard;
-- Verify: Still BufferIO dominant? Still 79% cache hit?

-- 2. Find the guilty query (5 min)
SELECT 
  substring(query, 1, 100),
  calls,
  mean_exec_time,
  shared_blks_read / calls as blks_per_call,
  round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) as hit_ratio
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY mean_exec_time * calls DESC
LIMIT 5;

-- 3. Understand WHY it's slow (10 min)
EXPLAIN (ANALYZE, BUFFERS, COSTS)
<the_slow_query>;

-- 4. Check if fix is needed (5 min)
-- Post EXPLAIN output here, we'll decode together

-- 5. Learn from this (8 min)
-- Document:
-- - What wait events you saw
-- - What the root cause was
-- - How you connected the dots
-- - What you'll check next time
```

### This Week

- Run full diagnostic each day at same time
- Track metrics in spreadsheet:
  - Wait sessions count
  - Buffer hit ratio
  - Top wait event
  - Slow query avg time
- Compare day-over-day: Are waits getting better or worse?

### This Month

- Create your own investigation template
- Share findings with team
- Build team runbook from your learnings
- Practice on different wait event patterns

---

## Summary: The Mental Model

```
WAIT EVENT (symptom)
    ↓
    ├─ What resource? (CPU, I/O, Lock, Memory)
    ↓
RESOURCE METRIC (diagnosis)
    ↓
    ├─ Buffer hit ratio? Seq scans? Connections? Locks?
    ↓
QUERY ANALYSIS (root cause)
    ↓
    ├─ EXPLAIN: What's slow?
    ├─ pg_stats: Why planner chose this?
    ├─ Indexes: What's missing/unused?
    ↓
RESOLUTION (fix)
    ↓
VERIFICATION (confirm)
```

**Your case in this framework:**
```
BufferIO (26 sessions)
    ↓ Resource?
Buffer hit ratio 79% (I/O problem)
    ↓ Why low?
Seq scans: 2B tuples (not using indexes)
    ↓ Why not?
Index exists but unused (need EXPLAIN)
    ↓ Fix?
[Waiting for EXPLAIN output to determine]
    ↓ Verify?
Check BufferIO → 0, cache hit → >95%
```
