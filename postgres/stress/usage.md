-- ============================================================================
-- USAGE GUIDE — PG Stats Diagnostic Framework V2
-- ============================================================================

-- Purpose:
--   This section provides a workflow for on call DBREs to diagnose
--   query planning issues, identify index opportunities, and validate
--   planner assumptions without auto-tuning.
--
-- Key Principle:
--   The framework generates hypotheses and recommendations. ALL actions
--   must be validated using EXPLAIN (ANALYZE, BUFFERS) and actual workload
--   observations before applying changes.

-- ============================================================================
-- 1. Check overall statistics health
-- ============================================================================
-- Identify tables with stale statistics, high modification counts, or
-- significant dead tuples.
SELECT * 
FROM dbre_stats_health
ORDER BY pct_changed_since_analyze DESC;

-- ============================================================================
-- 2. Analyze column cardinality, skew, and correlation
-- ============================================================================
-- Detect low-entropy columns, high-skew, and BRIN suitability.
SELECT * 
FROM dbre_column_selectivity_recommendations
ORDER BY schemaname, tablename, column_name;

-- ============================================================================
-- 3. Partial index opportunities
-- ============================================================================
-- Highlights columns with extreme skew where partial indexes could help.
-- Validate any suggested index with EXPLAIN.
SELECT * 
FROM dbre_partial_index_opportunities
ORDER BY dominant_freq DESC;

-- ============================================================================
-- 4. BRIN index candidates
-- ============================================================================
-- Focus on large append-only or time-series tables with strong correlation.
-- Check EXPLAIN plans for range queries before creating BRIN indexes.
SELECT * 
FROM dbre_brin_candidates
ORDER BY row_count DESC;

-- ============================================================================
-- 5. Join misestimation risk
-- ============================================================================
-- Flag joins with low-cardinality or random distribution that may
-- mislead the planner’s row estimates.
SELECT * 
FROM dbre_join_misestimation_risk
ORDER BY left_table, right_table;

-- ============================================================================
-- 6. Sequential scan root-cause analysis
-- ============================================================================
-- Understand why seq-scans occur and avoid knee-jerk index creation.
SELECT * 
FROM dbre_seqscan_root_cause
ORDER BY tablename;

-- ============================================================================
-- 7. Index optimization: duplicates and subsets
-- ============================================================================
-- Detect exact duplicate indexes
SELECT * 
FROM dbre_duplicate_indexes_exact
ORDER BY schema_name, table_name;

-- Detect subset indexes that may be redundant
SELECT * 
FROM dbre_duplicate_indexes_subset
ORDER BY schema_name, table_name;

-- ============================================================================
-- WORKFLOW RECOMMENDATIONS
-- ============================================================================
-- 1. Use dbre_stats_health to find stale stats and tables with many dead tuples.
-- 2. Examine dbre_column_selectivity_recommendations for low-cardinality columns,
--    high-skew columns, and BRIN potential.
-- 3. Review dbre_partial_index_opportunities and dbre_brin_candidates to generate
--    index hypotheses; validate with EXPLAIN.
-- 4. Use dbre_join_misestimation_risk to flag joins with misestimated costs.
-- 5. Investigate sequential scans using dbre_seqscan_root_cause before creating indexes.
-- 6. Optimize indexes with dbre_duplicate_indexes_exact and dbre_duplicate_indexes_subset.
-- 7. Re-run diagnostics after applying any changes to confirm improvements.
