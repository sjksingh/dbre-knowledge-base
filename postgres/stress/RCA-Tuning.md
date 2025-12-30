# PostgreSQL Workload Tuning Guide - Root Cause Analysis

## 🔍 Wait Event Analysis Framework

### Understanding PostgreSQL Wait Events

Wait events tell you **exactly** where queries spend time. Think of them as the database's "stack trace":

```
NO WAIT EVENT     = CPU-bound (good - database doing work)
IO Wait Events    = Disk bottleneck
IPC Wait Events   = Internal communication/synchronization
Lock Wait Events  = Contention between queries
Client Wait Events = Application/network issues
```

---

## 🚨 Analytics Workload Problem (50 Sessions)

### Symptom Summary
**Workload:** 50 concurrent analytics queries  
**Wait Events:** `LWLock: BufferMapping` (17+ seconds)  
**Root Cause:** Buffer pool contention + concurrent sequential scans  
**Impact:** 100% error rate, 60% cache hit ratio, all queries timeout

### Detailed RCA: Analytics Gridlock

## Immediate Actions (Apply in Order)

### 1. Reduce Concurrent Analytics Load
```bash
# Test with lower concurrency first
go run prod_reader.go -workload=analytics -sessions=10 -duration=2m
```

**Why:** 50 concurrent analytics queries saturate I/O and buffer pool

---

### 2. Increase RDS Parameter Group Settings

```sql
-- Connect to your RDS instance and check current settings:
SHOW shared_buffers;
SHOW work_mem;
SHOW effective_cache_size;
SHOW maintenance_work_mem;
SHOW max_parallel_workers_per_gather;
```

**Recommended for r5.2xlarge (64GB RAM):**
```
shared_buffers = 16GB           # 25% of RAM
effective_cache_size = 48GB     # 75% of RAM  
work_mem = 256MB                # Per sort/hash operation
maintenance_work_mem = 2GB
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
```

**How to apply:**
1. Modify RDS parameter group
2. Reboot instance (or wait for maintenance window)

---

### 3. Create Materialized Views for Hot Analytics

```sql
-- Daily volume aggregates (refreshed every hour)
CREATE MATERIALIZED VIEW mv_daily_volume AS
SELECT 
    transaction_date,
    COUNT(*) as txn_count,
    SUM(amount_usd) as total_volume,
    AVG(amount_usd) as avg_amount,
    COUNT(DISTINCT customer_id) as unique_customers
FROM financial_transactions 
WHERE is_deleted = false
GROUP BY transaction_date;

CREATE UNIQUE INDEX idx_mv_daily_volume_date ON mv_daily_volume(transaction_date);

-- Refresh strategy (run via cron/Lambda every hour)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_volume;
```

**Benefit:** Sub-millisecond query time vs. 17+ seconds

---

### 4. Add Partial Indexes for Analytics

```sql
-- Index for recent high-value transactions
CREATE INDEX CONCURRENTLY idx_recent_high_value 
ON financial_transactions(transaction_date, amount)
WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
AND is_deleted = false;

-- Index for risk analysis
CREATE INDEX CONCURRENTLY idx_recent_risk 
ON financial_transactions(transaction_date, risk_score, fraud_check_status)
WHERE risk_score > 70 
AND transaction_date >= CURRENT_DATE - INTERVAL '30 days';

-- Composite index for payment trends
CREATE INDEX CONCURRENTLY idx_payment_trends
ON financial_transactions(transaction_date, payment_method, amount_usd)
WHERE transaction_date >= CURRENT_DATE - INTERVAL '180 days';
```

**Why partial indexes?** 
- Smaller index size (only recent data)
- Faster scans
- Matches your WHERE clauses exactly

---

### 5. Enable Parallel Query Execution

```sql
-- Session-level (for testing):
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 100;
SET parallel_tuple_cost = 0.01;

-- Verify parallel execution:
EXPLAIN (ANALYZE, BUFFERS) 
SELECT transaction_date, COUNT(*), SUM(amount_usd)
FROM financial_transactions 
WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY transaction_date;

-- Look for "Parallel Seq Scan" or "Gather" nodes
```

---

## Testing Strategy

### Phase 1: Validate Single Query Performance
```bash
# Test one analytics query at a time
psql -c "EXPLAIN (ANALYZE, BUFFERS) <your_query>"
```

**Target metrics:**
- Execution time: <5 seconds
- Buffer hits: >95%
- No "Buffers: temp written" (disk sorts)

### Phase 2: Gradual Concurrency Ramp
```bash
# Start low
go run prod_reader.go -workload=analytics -sessions=5 -duration=2m

# Increase gradually
go run prod_reader.go -workload=analytics -sessions=10 -duration=2m
go run prod_reader.go -workload=analytics -sessions=20 -duration=2m
```

**Watch for:**
- QPS stabilizes (not dropping to 0)
- Error rate <1%
- Cache hit ratio >90%

### Phase 3: Mixed Workload (Realistic)
```bash
# 70% OLTP, 30% Analytics with moderate concurrency
go run prod_reader.go -workload=mixed -sessions=25 -duration=5m
```

---

## Monitoring During Load

### Check for Lock Contention
```sql
SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) as waiting_count,
    AVG(EXTRACT(EPOCH FROM (now() - query_start))) as avg_wait_seconds
FROM pg_stat_activity
WHERE state = 'active'
AND wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY waiting_count DESC;
```

**Red flags:**
- `LWLock | BufferMapping` = buffer pool contention
- `IO | DataFileRead` = insufficient shared_buffers
- `IO | BufFileWrite` = work_mem too small (disk sorts)

### Check Temp File Usage
```sql
SELECT 
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) as temp_size
FROM pg_stat_database
WHERE datname = 'avro';
```

**If temp_files growing:** Increase `work_mem`

### Check Query Performance
```sql
SELECT 
    query,
    calls,
    mean_exec_time,
    max_exec_time,
    stddev_exec_time
FROM pg_stat_statements
WHERE query LIKE '%financial_transactions%'
AND query NOT LIKE '%pg_stat%'
ORDER BY mean_exec_time DESC
LIMIT 10;
```

---

## Alternative: Separate Analytics Replica

**Best practice for production:**

1. **Create RDS Read Replica**
   - Dedicated for analytics workload
   - Can tune differently (more memory, parallel workers)
   - No impact on OLTP primary

2. **Route Analytics Queries to Replica**
   ```go
   // In your Go code
   analyticsPool := initConnectionPool(ctx, analyticsReplicaConnString, 10)
   ```

3. **Benefits:**
   - OLTP unaffected by analytics load
   - Tune each instance differently
   - Can lag slightly (acceptable for analytics)

---

## Expected Improvements

### After Tuning:
| Metric | Before | After (Target) |
|--------|--------|---------------|
| Query Time | 17+ sec | <5 sec |
| Error Rate | 100% | <1% |
| Cache Hit | 60-70% | >95% |
| Concurrent Sessions | 50 (gridlock) | 10-20 (stable) |
| QPS | ~5 (unstable) | 50-100 (stable) |

---

## Quick Wins (Implement Today)

1. ✅ **Reduce sessions to 10** for analytics workload
2. ✅ **Increase statement_timeout to 120s** (already done in code)
3. ✅ **Increase work_mem to 256MB** (already done in code)
4. ✅ **Create materialized view for daily_volume** (most common query)
5. ✅ **Enable parallel query** (if RDS allows)

## Medium-term (This Week)

1. 📊 Create remaining materialized views
2. 🔍 Add partial indexes for date ranges
3. 📈 Set up CloudWatch metrics for lock waits
4. 🧪 Test with realistic concurrency (10-15 for analytics)

## Long-term (Production)

1. 🔄 Deploy read replica for analytics
2. 📦 Consider TimescaleDB extension for time-series data
3. 🎯 Partition table by transaction_date (if grows beyond 10M rows)
4. 💾 Evaluate columnar storage (pg_columnar) for analytics

---


##  classic cascade pattern
7 sessions waiting on BufferIO: 6.10-6.30 seconds
1 session waiting on DataFileRead: 6.25 seconds
ALL running the SAME QUERY: is_flagged = true

One session (pid 18054) does a DataFileRead (6.25s) - reading pages from disk
Six other sessions (pids 18059-18070) hit BufferIO (6.10-6.30s) - waiting for that I/O to complete
They're all querying the same data that's not in cache

```sql
-- Check if the covering index we created is helping
EXPLAIN (ANALYZE, BUFFERS) 
SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
FROM financial_transactions
WHERE is_flagged = true 
  AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY risk_score DESC
LIMIT 100;

-- Check index usage stats
SELECT 
  indexrelname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE relname = 'financial_transactions'
  AND indexrelname LIKE '%flagged%'
ORDER BY idx_scan DESC;
```

Statistics... 🤔

```sql
-- Force statistics update
ANALYZE financial_transactions;

-- Then check
SELECT 
  attname,
  n_distinct,
  most_common_vals,
  most_common_freqs
FROM pg_stats
WHERE tablename = 'financial_transactions'
  AND attname IN ('is_flagged', 'transaction_date');

-- Check what the planner thinks
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
FROM financial_transactions
WHERE is_flagged = true 
  AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY risk_score DESC
LIMIT 100;
```





## Next Steps

Run this to verify fixes:
```bash
# Test with reduced load
go run prod_reader.go -workload=analytics -sessions=10 -duration=2m

# Monitor in another terminal
psql -c "SELECT wait_event_type, wait_event, COUNT(*) 
         FROM pg_stat_activity 
         WHERE state = 'active' 
         GROUP BY 1,2"
```

**Success criteria:**
- No BufferMapping locks
- Cache hit >90%
- Error rate <5%
- Queries complete in <10 seconds
