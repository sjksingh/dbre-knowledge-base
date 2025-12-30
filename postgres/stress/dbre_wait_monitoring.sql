-- ============================================================================
-- Platform DBRE Wait Event Monitoring Views
-- wait event analysis with duration, severity, and context
-- ============================================================================

-- ============================================================================
-- VIEW 1: Enhanced Active Waits with Duration and Severity
-- ============================================================================

CREATE OR REPLACE VIEW dbre_wait_analysis AS
SELECT 
  wait_event_type,
  wait_event,
  count(*) AS waiting_sessions,
  
  -- Duration metrics (critical for severity assessment)
  min(EXTRACT(EPOCH FROM (now() - query_start))) AS min_wait_seconds,
  max(EXTRACT(EPOCH FROM (now() - query_start))) AS max_wait_seconds,
  avg(EXTRACT(EPOCH FROM (now() - query_start)))::numeric(10,2) AS avg_wait_seconds,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (now() - query_start)))::numeric(10,2) AS p95_wait_seconds,
  
  -- State breakdown
  count(*) FILTER (WHERE EXTRACT(EPOCH FROM (now() - query_start)) < 1) AS wait_under_1s,
  count(*) FILTER (WHERE EXTRACT(EPOCH FROM (now() - query_start)) BETWEEN 1 AND 5) AS wait_1_5s,
  count(*) FILTER (WHERE EXTRACT(EPOCH FROM (now() - query_start)) BETWEEN 5 AND 30) AS wait_5_30s,
  count(*) FILTER (WHERE EXTRACT(EPOCH FROM (now() - query_start)) > 30) AS wait_over_30s,
  
  -- Severity indicator
  CASE 
    WHEN count(*) >= 10 THEN '🚨 CRITICAL'
    WHEN count(*) >= 5 OR max(EXTRACT(EPOCH FROM (now() - query_start))) > 30 THEN '⚠️  WARNING'
    WHEN max(EXTRACT(EPOCH FROM (now() - query_start))) > 5 THEN '⚡ ATTENTION'
    ELSE '✅ NORMAL'
  END AS severity,
  
  -- Actionable context
  CASE wait_event
    WHEN 'BufferMapping' THEN 'Action: Check buffer hit ratio, consider increasing shared_buffers'
    WHEN 'DataFileRead' THEN 'Action: Review indexes, check if seq scans occurring, verify working set fits in cache'
    WHEN 'BufferIO' THEN 'Action: Check for hot pages, review concurrent query patterns'
    WHEN 'WALWrite' THEN 'Action: Check wal_buffers, consider faster storage for WAL'
    WHEN 'DataFileExtend' THEN 'Action: Pre-allocate space or check for storage contention'
    WHEN 'ClientRead' THEN 'Action: Client not consuming results fast enough'
    ELSE 'Action: Review PostgreSQL documentation for ' || wait_event
  END AS recommended_action,
  
  -- Sample queries (truncated for readability)
  string_agg(DISTINCT left(query, 120), E'\n---\n') AS sample_queries,
  
  -- Session details
  array_agg(DISTINCT pid ORDER BY pid) AS session_pids,
  array_agg(DISTINCT usename) FILTER (WHERE usename IS NOT NULL) AS users,
  array_agg(DISTINCT application_name) FILTER (WHERE application_name IS NOT NULL) AS applications,
  
  -- Query start times for trend analysis
  min(query_start) AS oldest_query_start,
  max(query_start) AS newest_query_start
  
FROM pg_stat_activity
WHERE state = 'active'
  AND wait_event IS NOT NULL
  AND backend_type = 'client backend'
GROUP BY wait_event_type, wait_event
ORDER BY 
  CASE 
    WHEN count(*) >= 10 THEN 1
    WHEN count(*) >= 5 THEN 2
    WHEN max(EXTRACT(EPOCH FROM (now() - query_start))) > 30 THEN 3
    ELSE 4
  END,
  count(*) DESC;

COMMENT ON VIEW dbre_wait_analysis IS 
'Staff DBRE view: Active wait events with duration, severity assessment, and actionable recommendations';

-- ============================================================================
-- VIEW 2: Wait Event History Tracker (requires logging to table)
-- ============================================================================

-- First create the tracking table
CREATE TABLE IF NOT EXISTS wait_event_history (
  captured_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  wait_event_type TEXT NOT NULL,
  wait_event TEXT NOT NULL,
  waiting_sessions INT NOT NULL,
  max_wait_seconds NUMERIC(10,2),
  avg_wait_seconds NUMERIC(10,2),
  sample_query TEXT,
  PRIMARY KEY (captured_at, wait_event_type, wait_event)
);

-- Create index for time-series queries
CREATE INDEX IF NOT EXISTS idx_wait_history_time 
ON wait_event_history (captured_at DESC);

CREATE INDEX IF NOT EXISTS idx_wait_history_event 
ON wait_event_history (wait_event, captured_at DESC);

-- Function to capture wait events (call this from cron or monitoring system)
CREATE OR REPLACE FUNCTION capture_wait_events()
RETURNS void AS $$
BEGIN
  INSERT INTO wait_event_history (
    captured_at,
    wait_event_type,
    wait_event,
    waiting_sessions,
    max_wait_seconds,
    avg_wait_seconds,
    sample_query
  )
  SELECT 
    now(),
    wait_event_type,
    wait_event,
    count(*)::int,
    max(EXTRACT(EPOCH FROM (now() - query_start)))::numeric(10,2),
    avg(EXTRACT(EPOCH FROM (now() - query_start)))::numeric(10,2),
    left(string_agg(DISTINCT query, ' | '), 500)
  FROM pg_stat_activity
  WHERE state = 'active'
    AND wait_event IS NOT NULL
    AND backend_type = 'client backend'
  GROUP BY wait_event_type, wait_event;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION capture_wait_events() IS 
'Call every 5-10 seconds to build wait event history: SELECT capture_wait_events();';

-- View for trending analysis
CREATE OR REPLACE VIEW dbre_wait_trends AS
SELECT 
  wait_event_type,
  wait_event,
  
  -- Last 5 minutes
  count(*) FILTER (WHERE captured_at >= now() - INTERVAL '5 minutes') AS occurrences_5m,
  max(waiting_sessions) FILTER (WHERE captured_at >= now() - INTERVAL '5 minutes') AS max_sessions_5m,
  avg(max_wait_seconds) FILTER (WHERE captured_at >= now() - INTERVAL '5 minutes')::numeric(10,2) AS avg_max_wait_5m,
  
  -- Last 1 hour
  count(*) FILTER (WHERE captured_at >= now() - INTERVAL '1 hour') AS occurrences_1h,
  max(waiting_sessions) FILTER (WHERE captured_at >= now() - INTERVAL '1 hour') AS max_sessions_1h,
  
  -- Last 24 hours
  count(*) FILTER (WHERE captured_at >= now() - INTERVAL '24 hours') AS occurrences_24h,
  max(waiting_sessions) FILTER (WHERE captured_at >= now() - INTERVAL '24 hours') AS max_sessions_24h,
  
  -- Trend indicator
  CASE 
    WHEN count(*) FILTER (WHERE captured_at >= now() - INTERVAL '5 minutes') > 
         count(*) FILTER (WHERE captured_at >= now() - INTERVAL '1 hour') / 12.0 * 1.5 
    THEN '📈 INCREASING'
    WHEN count(*) FILTER (WHERE captured_at >= now() - INTERVAL '5 minutes') = 0 
         AND count(*) FILTER (WHERE captured_at >= now() - INTERVAL '1 hour') > 0
    THEN '📉 RESOLVED'
    ELSE '➡️  STABLE'
  END AS trend
  
FROM wait_event_history
WHERE captured_at >= now() - INTERVAL '24 hours'
GROUP BY wait_event_type, wait_event
HAVING count(*) FILTER (WHERE captured_at >= now() - INTERVAL '1 hour') > 0
ORDER BY occurrences_5m DESC, max_sessions_5m DESC;

-- ============================================================================
-- VIEW 3: Detailed Wait Event Sessions (for deep investigation)
-- ============================================================================

CREATE OR REPLACE VIEW dbre_waiting_sessions_detail AS
SELECT 
  pid,
  usename,
  application_name,
  client_addr,
  backend_start,
  
  -- Wait details
  wait_event_type,
  wait_event,
  state,
  
  -- Timing
  now() - query_start AS total_duration,
  now() - state_change AS time_in_current_state,
  EXTRACT(EPOCH FROM (now() - query_start))::numeric(10,2) AS wait_seconds,
  
  -- Query context
  left(query, 200) AS query_preview,
  query_start,
  
  -- Lock information (if applicable)
  (SELECT count(*) FROM pg_locks WHERE pg_locks.pid = pg_stat_activity.pid) AS held_locks,
  
  -- Backend details
  backend_type,
  backend_xid,
  backend_xmin,
  
  -- Classification
  CASE 
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 60 THEN '🚨 VERY LONG (>1min)'
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 30 THEN '⚠️  LONG (30s-1m)'
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 5 THEN '⚡ MODERATE (5-30s)'
    ELSE '✅ SHORT (<5s)'
  END AS duration_class
  
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND state = 'active'
  AND backend_type = 'client backend'
ORDER BY 
  CASE 
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 60 THEN 1
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 30 THEN 2
    WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 5 THEN 3
    ELSE 4
  END,
  wait_seconds DESC;

-- ============================================================================
-- VIEW 4: Wait Event Correlation with System Metrics
-- ============================================================================

CREATE OR REPLACE VIEW dbre_wait_system_correlation AS
SELECT 
  -- Current wait events summary
  (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') AS total_waiting_sessions,
  (SELECT count(DISTINCT wait_event) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') AS distinct_wait_events,
  
  -- Connection pool health
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND backend_type = 'client backend') AS active_connections,
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle' AND backend_type = 'client backend') AS idle_connections,
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction' AND backend_type = 'client backend') AS idle_in_transaction,
  (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
  
  -- Buffer cache status
  (SELECT round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) 
   FROM pg_stat_database WHERE datname = current_database()) AS buffer_hit_ratio,
  
  -- Checkpoint status
  (SELECT checkpoints_timed FROM pg_stat_bgwriter) AS checkpoints_timed,
  (SELECT checkpoints_req FROM pg_stat_bgwriter) AS checkpoints_requested,
  
  -- Database size
  (SELECT pg_size_pretty(pg_database_size(current_database()))) AS database_size,
  
  -- Most common wait event
  (SELECT wait_event FROM pg_stat_activity 
   WHERE wait_event IS NOT NULL AND state = 'active' 
   GROUP BY wait_event ORDER BY count(*) DESC LIMIT 1) AS top_wait_event,
  
  -- Timestamp
  now() AS captured_at;

-- ============================================================================
-- VIEW 5: Quick Health Dashboard (single-row summary)
-- ============================================================================

CREATE OR REPLACE VIEW dbre_wait_health_dashboard AS
SELECT 
  -- Overall health indicator
  CASE 
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') >= 10 
    THEN '🚨 CRITICAL - High Wait Activity'
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'BufferMapping' AND state = 'active') >= 5 
    THEN '⚠️  WARNING - Buffer Contention'
    WHEN (SELECT max(EXTRACT(EPOCH FROM (now() - query_start))) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') > 30
    THEN '⚠️  WARNING - Long Wait Times'
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') > 0
    THEN '⚡ ATTENTION - Some Waits Present'
    ELSE '✅ HEALTHY - No Significant Waits'
  END AS overall_status,
  
  -- Key metrics
  (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') AS waiting_sessions,
  (SELECT max(EXTRACT(EPOCH FROM (now() - query_start)))::numeric(10,2) 
   FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') AS longest_wait_seconds,
  (SELECT wait_event FROM pg_stat_activity 
   WHERE wait_event IS NOT NULL AND state = 'active' 
   GROUP BY wait_event ORDER BY count(*) DESC LIMIT 1) AS most_common_wait,
  
  -- Top 3 wait events
  (SELECT string_agg(wait_event || ' (' || cnt || ')', ', ' ORDER BY cnt DESC)
   FROM (
     SELECT wait_event, count(*) as cnt 
     FROM pg_stat_activity 
     WHERE wait_event IS NOT NULL AND state = 'active'
     GROUP BY wait_event 
     ORDER BY cnt DESC 
     LIMIT 3
   ) top_waits
  ) AS top_3_waits,
  
  -- System health
  (SELECT round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) 
   FROM pg_stat_database WHERE datname = current_database()) AS buffer_hit_ratio,
  (SELECT setting FROM pg_settings WHERE name = 'shared_buffers') AS shared_buffers,
  
  -- Actionable recommendation
  CASE 
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'BufferMapping' AND state = 'active') >= 5
    THEN 'Investigate buffer pool contention - check sequential scans and shared_buffers sizing'
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'DataFileRead' AND state = 'active') >= 5
    THEN 'High disk I/O - review indexes and increase shared_buffers'
    WHEN (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') >= 10
    THEN 'Multiple wait types - review connection pooling and query patterns'
    WHEN (SELECT max(EXTRACT(EPOCH FROM (now() - query_start))) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND state = 'active') > 60
    THEN 'Long-running queries detected - investigate blocking or slow queries'
    ELSE 'No immediate action required'
  END AS recommendation,
  
  now() AS checked_at;

-- ============================================================================
-- USAGE EXAMPLES
-- ============================================================================

/*
-- 1. Quick health check (recommended for watch/monitoring)
SELECT * FROM dbre_wait_health_dashboard;

-- 2. Detailed wait analysis (replaces your old view)
SELECT 
  wait_event_type,
  wait_event,
  waiting_sessions,
  min_wait_seconds,
  max_wait_seconds,
  avg_wait_seconds,
  severity,
  recommended_action
FROM dbre_wait_analysis;

-- 3. See individual waiting sessions with durations
SELECT 
  pid,
  wait_event,
  wait_seconds,
  duration_class,
  left(query_preview, 200) as query
FROM dbre_waiting_sessions_detail
ORDER BY wait_seconds DESC;


-- 4. Detailed wait analysis with duration and severity
SELECT * FROM dbre_wait_analysis;

-- 5. Individual session investigation
SELECT * FROM dbre_waiting_sessions_detail WHERE duration_class LIKE '%LONG%';

-- 6. Historical trending (requires capture_wait_events() running)
SELECT * FROM dbre_wait_trends WHERE trend = '📈 INCREASING';

-- 7. System correlation view
SELECT * FROM dbre_wait_system_correlation;

-- ============================================================================
-- MONITORING SETUP
-- ============================================================================

-- Option 1: Manual periodic capture (run every 5-10 seconds)
SELECT capture_wait_events();

-- Option 2: Using watch in psql
\watch 5
SELECT * FROM dbre_wait_health_dashboard;

-- Option 3: Set up pg_cron (if available in RDS)
-- SELECT cron.schedule('capture-waits', '*/10 * * * *', 'SELECT capture_wait_events();');

-- ============================================================================
-- ALERTING QUERIES (for integration with monitoring systems)
-- ============================================================================

-- Alert if critical waits present
SELECT 
  overall_status,
  waiting_sessions,
  longest_wait_seconds,
  recommendation
FROM dbre_wait_health_dashboard
WHERE overall_status LIKE '🚨%' OR overall_status LIKE '⚠️%';

-- Alert if specific wait type exceeds threshold
SELECT 
  wait_event_type,
  wait_event,
  waiting_sessions,
  max_wait_seconds,
  severity
FROM dbre_wait_analysis
WHERE severity IN ('🚨 CRITICAL', '⚠️  WARNING');

*/

-- ============================================================================
-- CLEANUP OLD HISTORY (run periodically)
-- ============================================================================

-- Keep only last 7 days of history
-- DELETE FROM wait_event_history WHERE captured_at < now() - INTERVAL '7 days';
