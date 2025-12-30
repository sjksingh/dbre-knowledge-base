-- ============================================================================
-- Platform DBRE pg_stats Diagnostic Framework - PG14 COMPATIBLE
-- ============================================================================

-- Clean slate
DROP VIEW IF EXISTS dbre_stats_health CASCADE;
DROP VIEW IF EXISTS dbre_column_stats_analysis CASCADE;
DROP VIEW IF EXISTS dbre_multicolumn_stats CASCADE;
DROP VIEW IF EXISTS dbre_index_stats_matcher CASCADE;
DROP FUNCTION IF EXISTS dbre_analyze_column_for_query(TEXT, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS dbre_stats_diagnostic_workflow(TEXT, TEXT) CASCADE;

-- ============================================================================
-- VIEW 1: Statistics Health Dashboard
-- ============================================================================

CREATE VIEW dbre_stats_health AS
SELECT 
  schemaname,
  relname as tablename,
  n_live_tup as current_live_rows,
  (SELECT c.reltuples::bigint FROM pg_class c WHERE c.oid = stat.relid) as stats_estimated_rows,
  last_analyze,
  last_autoanalyze,
  age(now(), COALESCE(last_analyze, last_autoanalyze)) as time_since_analyze,
  n_mod_since_analyze,
  round((100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0))::numeric, 2) as pct_changed_since_analyze,
  n_dead_tup,
  round((100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0))::numeric, 2) as dead_tuple_pct,
  CASE 
    WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN '🚨 STALE'
    WHEN n_mod_since_analyze > n_live_tup * 0.1 THEN '⚠️  AGING'
    WHEN age(now(), COALESCE(last_analyze, last_autoanalyze)) > INTERVAL '7 days' THEN '⚠️  OLD'
    WHEN n_dead_tup > n_live_tup * 0.1 THEN '⚠️  BLOATED'
    ELSE '✅ FRESH'
  END as stats_health,
  CASE 
    WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN 'ANALYZE ' || schemaname || '.' || relname || ';'
    WHEN n_dead_tup > n_live_tup * 0.2 THEN 'VACUUM ANALYZE ' || schemaname || '.' || relname || ';'
    ELSE NULL
  END as recommended_action
FROM pg_stat_user_tables stat
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n_live_tup DESC;

-- ============================================================================
-- VIEW 2: Column Statistics Analysis
-- ============================================================================

CREATE VIEW dbre_column_stats_analysis AS
SELECT 
  schemaname,
  tablename,
  attname as column_name,
  n_distinct,
  CASE 
    WHEN n_distinct < 0 THEN round((abs(n_distinct) * (SELECT n_live_tup FROM pg_stat_user_tables WHERE tablename = s.tablename AND schemaname = s.schemaname))::numeric)::bigint
    ELSE n_distinct::bigint
  END as estimated_distinct_values,
  null_frac,
  round((null_frac * 100)::numeric, 2) as null_pct,
  avg_width,
  correlation,
  CASE 
    WHEN correlation IS NULL THEN 'N/A'
    WHEN abs(correlation) > 0.9 THEN '✅ HIGH'
    WHEN abs(correlation) > 0.5 THEN '⚡ MODERATE'
    ELSE '⚠️  LOW'
  END as correlation_assessment,
  most_common_vals,
  most_common_freqs
FROM pg_stats s
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename, attname;

-- ============================================================================
-- FUNCTION: Analyze Column for Query
-- ============================================================================

CREATE FUNCTION dbre_analyze_column_for_query(
  p_schema TEXT,
  p_table TEXT,
  p_column TEXT
)
RETURNS TABLE (
  metric TEXT,
  value TEXT,
  interpretation TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    'Column'::TEXT,
    (p_schema || '.' || p_table || '.' || p_column)::TEXT,
    'Target column for analysis'::TEXT
  
  UNION ALL
  
  SELECT 
    'Distinct Values'::TEXT,
    CASE 
      WHEN n_distinct < 0 THEN 
        'Estimated: ' || round((abs(n_distinct) * (SELECT n_live_tup FROM pg_stat_user_tables 
          WHERE tablename = p_table AND schemaname = p_schema))::numeric)::text
      ELSE n_distinct::text
    END,
    CASE 
      WHEN n_distinct = 1 THEN '🚨 Single value'
      WHEN n_distinct = 2 THEN '✅ Boolean/binary - good for partial index'
      WHEN n_distinct < 10 THEN '⚠️  Very low cardinality'
      WHEN n_distinct < 100 THEN '✅ Low cardinality'
      ELSE '⚡ High cardinality'
    END
  FROM pg_stats
  WHERE schemaname = p_schema AND tablename = p_table AND attname = p_column
  
  UNION ALL
  
  SELECT 
    'Null Percentage'::TEXT,
    round((null_frac * 100)::numeric, 2)::text || '%',
    CASE 
      WHEN null_frac > 0.5 THEN '⚠️  High nulls'
      WHEN null_frac > 0.1 THEN '✅ Some nulls'
      ELSE '✅ Few nulls'
    END
  FROM pg_stats
  WHERE schemaname = p_schema AND tablename = p_table AND attname = p_column
  
  UNION ALL
  
  SELECT 
    'Physical Correlation'::TEXT,
    COALESCE(round(correlation::numeric, 3)::text, 'N/A'),
    CASE 
      WHEN correlation IS NULL THEN 'No correlation data'
      WHEN abs(correlation) > 0.9 THEN '✅ Excellent for index scans'
      WHEN abs(correlation) > 0.7 THEN '✅ Good'
      WHEN abs(correlation) > 0.3 THEN '⚡ Moderate'
      ELSE '⚠️  Poor - random I/O'
    END
  FROM pg_stats
  WHERE schemaname = p_schema AND tablename = p_table AND attname = p_column
  
  UNION ALL
  
  SELECT 
    'Most Common Value'::TEXT,
    COALESCE(most_common_vals::text, 'N/A'),
    COALESCE('Freq: ' || most_common_freqs[1]::text, 'No MCV data')
  FROM pg_stats
  WHERE schemaname = p_schema AND tablename = p_table AND attname = p_column;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEW 3: Index Statistics Matcher
-- ============================================================================

CREATE VIEW dbre_index_stats_matcher AS
SELECT 
  ui.schemaname,
  ui.relname as tablename,
  ui.indexrelname as indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(ui.indexrelid)) as index_size,
  CASE 
    WHEN idx_scan = 0 THEN '❌ UNUSED'
    WHEN idx_scan < 10 THEN '⚠️  RARELY USED'
    WHEN idx_scan < 100 THEN '✅ USED'
    ELSE '✅ ACTIVE'
  END as assessment,
  (SELECT indexdef FROM pg_indexes WHERE schemaname = ui.schemaname 
   AND tablename = ui.relname AND indexname = ui.indexrelname) as indexdef
FROM pg_stat_user_indexes ui
WHERE ui.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 
  CASE WHEN idx_scan = 0 THEN 0 ELSE 1 END,
  pg_relation_size(ui.indexrelid) DESC;

-- ============================================================================
-- FUNCTION: Diagnostic Workflow
-- ============================================================================

CREATE FUNCTION dbre_stats_diagnostic_workflow(
  p_table TEXT,
  p_schema TEXT DEFAULT 'public'
)
RETURNS TABLE (
  step TEXT,
  finding TEXT,
  action TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    '1. Statistics Freshness'::TEXT,
    'Last analyzed: ' || COALESCE(age(now(), last_analyze)::text, 'Never') || 
    ', Modified: ' || n_mod_since_analyze::text ||
    ' (' || round((100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0))::numeric, 1)::text || '%)',
    CASE 
      WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN 'ANALYZE ' || p_schema || '.' || p_table || ';'
      ELSE 'Stats are fresh'
    END
  FROM pg_stat_user_tables
  WHERE relname = p_table AND schemaname = p_schema;
  
  RETURN QUERY
  SELECT 
    '2. Sequential Scans'::TEXT,
    'Seq scans: ' || seq_scan::text || ', Tuples: ' || seq_tup_read::text ||
    ', Index scans: ' || COALESCE(idx_scan::text, '0'),
    CASE 
      WHEN seq_tup_read > COALESCE(idx_tup_fetch, 0) * 2 THEN 'High seq scan ratio!'
      ELSE 'OK'
    END
  FROM pg_stat_user_tables
  WHERE relname = p_table AND schemaname = p_schema;
  
  RETURN QUERY
  SELECT 
    '3. Unused Indexes'::TEXT,
    'Count: ' || count(*)::text || ', Space: ' || 
    COALESCE(pg_size_pretty(sum(pg_relation_size(indexrelid))), '0 bytes'),
    string_agg(indexrelname, ', ')
  FROM pg_stat_user_indexes
  WHERE relname = p_table 
    AND schemaname = p_schema
    AND idx_scan = 0;
  
  RETURN QUERY
  SELECT 
    '4. Table Bloat'::TEXT,
    'Dead tuples: ' || n_dead_tup::text || ' (' || 
    round((100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0))::numeric, 1)::text || '%)',
    CASE 
      WHEN n_dead_tup > n_live_tup * 0.2 THEN 'VACUUM ANALYZE needed'
      ELSE 'OK'
    END
  FROM pg_stat_user_tables
  WHERE relname = p_table AND schemaname = p_schema;
END;
$$ LANGUAGE plpgsql;

/*
-- ============================================================================
-- USAGE GUIDE
-- ============================================================================
-- RUN THE FRAMEWORK INSTALL
-- ============================================================================
-- \i pg_stats_framework.sql
-- ============================================================================

-- Now run these diagnostics:

-- 1. Check stats health
-- SELECT * FROM dbre_stats_health WHERE tablename = 'financial_transactions';

-- 2. Analyze is_flagged column
-- SELECT * FROM dbre_analyze_column_for_query('public', 'financial_transactions', 'is_flagged');

-- 3. Check all indexes
-- SELECT * FROM dbre_index_stats_matcher WHERE tablename = 'financial_transactions';

-- 4. Full diagnostic
-- SELECT * FROM dbre_stats_diagnostic_workflow('financial_transactions');

-- 5. Raw pg_stats
-- SELECT attname, n_distinct, null_frac, most_common_vals, most_common_freqs, correlation
-- FROM pg_stats WHERE tablename = 'financial_transactions' AND attname = 'is_flagged';


-- 6. See all indexes and their usage

SELECT 
  indexname,
  idx_scan,
  index_size,
  assessment
FROM dbre_index_stats_matcher 
WHERE tablename = 'financial_transactions'
ORDER BY idx_scan;

-- 7. Full diagnostic workflow
SELECT * FROM dbre_stats_diagnostic_workflow('financial_transactions');

-- 8. Raw pg_stats for is_flagged
SELECT 
  attname,
  n_distinct,
  null_frac,
  most_common_vals,
  most_common_freqs,
  correlation
FROM pg_stats 
WHERE tablename = 'financial_transactions' 
  AND attname IN ('is_flagged', 'transaction_date');

-- ============================================================================
-- IF STATS ARE STALE, UPDATE THEM
-- ============================================================================
--ANALYZE financial_transactions;

-- Then re-run diagnostics to see if it helped
--SELECT * FROM dbre_analyze_column_for_query('public', 'financial_transactions', 'is_flagged');
*/
