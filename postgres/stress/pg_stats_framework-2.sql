-- ============================================================================
-- PG Stats Diagnostic Framework — V2
-- 
-- Purpose:
--   A SQL-only toolkit for **forensic investigation of query planning issues**
--   using pg_stats + pg_stat_user_tables + pg_class.
--
-- Staff-level focus areas:
--   • Detect planner misestimation
--   • Identify skew + low-entropy columns
--   • Find BRIN vs BTREE opportunities
--   • Expose partial-index candidates
--   • Diagnose seq-scan root-causes
--
-- NOTE: This framework does NOT “auto-tune”. It provides hypotheses and actions
--       that must be validated via EXPLAIN (ANALYZE, BUFFERS) + workload review.
-- ============================================================================


-- ============================================================================
-- CLEAN SLATE
-- ============================================================================

DROP VIEW IF EXISTS dbre_column_selectivity_recommendations CASCADE;
DROP VIEW IF EXISTS dbre_brin_candidates CASCADE;
DROP VIEW IF EXISTS dbre_partial_index_opportunities CASCADE;
DROP VIEW IF EXISTS dbre_join_misestimation_risk CASCADE;
DROP VIEW IF EXISTS dbre_seqscan_root_cause CASCADE;


-- ============================================================================
-- VIEW 1: Column Selectivity & Skew Analysis
-- Detects low-entropy columns, skew, and BRIN ordering potential.
-- ============================================================================

CREATE VIEW dbre_column_selectivity_recommendations AS
SELECT
  s.schemaname,
  s.tablename,
  s.attname AS column_name,
  s.n_distinct,
  s.null_frac,
  s.correlation,

  -- Cast avoids ANYARRAY issues
  s.most_common_vals::text AS most_common_vals,
  s.most_common_freqs,

  -- Planner selectivity perspective
  CASE
    WHEN s.n_distinct = 1
      THEN '❌ Single constant value — indexing provides ZERO benefit'
    WHEN s.n_distinct BETWEEN 2 AND 5
      THEN '⚠️ Very low cardinality — avoid BTREE, consider PARTIAL index'
    WHEN s.n_distinct < 0
      THEN '⚡ High cardinality — index useful if predicate selective'
    ELSE
      '🟡 Medium cardinality — depends on workload access patterns'
  END AS selectivity_assessment,

  -- Identify extreme skew
  CASE
    WHEN s.most_common_freqs[1] > 0.95
      THEN '🔥 Extreme skew — candidate for rare-case partial index'
    WHEN s.most_common_freqs[1] > 0.80
      THEN '⚠️ High skew — review workload filters'
    ELSE
      '🟢 Distribution looks reasonable'
  END AS skew_assessment,

  -- BRIN ordering heuristic
  CASE
    WHEN s.correlation > 0.8
      THEN '🟢 Strong ordering — BRIN may outperform BTREE on large tables'
    WHEN s.correlation < -0.8
      THEN '🟢 Reverse-ordered — still BRIN-friendly if append-only'
    ELSE
      '⚠️ Weak correlation — BRIN not recommended'
  END AS brin_suitability

FROM pg_stats s
WHERE s.schemaname NOT IN ('pg_catalog','information_schema');


-- ============================================================================
-- VIEW 2: BRIN Index Candidate Detector
-- Focus: large append-only / time-series tables with physical ordering.
-- ============================================================================

CREATE VIEW dbre_brin_candidates AS
SELECT
  s.schemaname,
  s.tablename,
  s.attname AS column_name,
  c.reltuples AS row_count,
  pg_size_pretty(pg_total_relation_size(c.oid::regclass)) AS table_size,
  s.correlation,

  CASE
    WHEN c.reltuples < 1000000
      THEN 'LOW VALUE — table too small for BRIN benefit'
    WHEN s.correlation > 0.75
      THEN 'STRONG candidate for BRIN'
    WHEN s.correlation < -0.75
      THEN 'Candidate (descending insert order)'
    ELSE
      'Not suitable for BRIN — weak ordering'
  END AS recommendation,

  'WHY: BRIN reduces I/O for append-only / range-filter workloads.' AS justification,
  'VERIFY: EXPLAIN (ANALYZE, BUFFERS) — expect fewer heap blocks read.' AS verification_hint

FROM pg_stats s
JOIN pg_class c
  ON c.relname = s.tablename
 AND c.relnamespace = s.schemaname::regnamespace
WHERE s.correlation IS NOT NULL
  AND s.null_frac < 0.5
  AND s.attname NOT ILIKE '%id%';


-- ============================================================================
-- VIEW 3: Partial-Index Opportunity Detector
-- Detects extreme skew where rare-case filtering benefits from a partial index.
-- ============================================================================

CREATE VIEW dbre_partial_index_opportunities AS
SELECT
  s.schemaname,
  s.tablename,
  s.attname AS column_name,

  -- Safe extraction of dominant value
  (array_to_json(s.most_common_vals) ->> 0) AS dominant_value,
  s.most_common_freqs[1] AS dominant_freq,

  -- Generates a *candidate* index definition — not auto-applied
  'CREATE INDEX CONCURRENTLY idx_' ||
  s.tablename || '_' || s.attname || '_rare_only ON ' ||
  s.schemaname || '.' || s.tablename || '(' || s.attname || ')' ||
  ' WHERE ' || s.attname || ' <> ' ||
  quote_literal(array_to_json(s.most_common_vals) ->> 0) || ';'
  AS suggested_index,

  'WHY: Column skew causes full-table scans for rare cases — isolate cold-path queries via partial index.'
  AS justification,

  'VERIFY: Re-run workload + ensure pg_stat_user_indexes.idx_scan increases ONLY for rare-case queries.'
  AS verification_hint

FROM pg_stats s
WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
  AND s.most_common_freqs IS NOT NULL
  AND s.most_common_freqs[1] > 0.90
  AND s.n_distinct > 2;  -- avoid boolean columns


-- ============================================================================
-- VIEW 4: Join Cardinality Mis-Estimation Risk
-- Purpose: flag joins where low cardinality or randomness misleads the planner.
-- ============================================================================

CREATE VIEW dbre_join_misestimation_risk AS
SELECT
  s1.tablename AS left_table,
  s1.attname   AS left_column,
  s2.tablename AS right_table,
  s2.attname   AS right_column,
  s1.n_distinct AS left_distinct,
  s2.n_distinct AS right_distinct,

  CASE
    WHEN s1.n_distinct < 10 OR s2.n_distinct < 10
      THEN '⚠️ LOW cardinality — planner may underestimate join cost'
    WHEN abs(s1.correlation) < 0.2 OR abs(s2.correlation) < 0.2
      THEN '⚠️ RANDOM distribution — hash join may outperform nested-loop'
    ELSE
      'OK'
  END AS risk_assessment,

  'ACTION: Run EXPLAIN (ANALYZE, BUFFERS) and compare row estimates vs actuals.'
  AS recommendation

FROM pg_stats s1
JOIN pg_stats s2
  ON s1.attname = s2.attname
 AND s1.tablename <> s2.tablename
 AND s1.schemaname = s2.schemaname      -- reduce false matches
 AND s1.n_distinct <= s2.n_distinct;    -- heuristic FK-like direction


-- ============================================================================
-- VIEW 5: Sequential-Scan Root-Cause Analysis
-- Goal: explain WHY seq-scans occur instead of blindly assuming they are bad.
-- ============================================================================

CREATE VIEW dbre_seqscan_root_cause AS
SELECT
  t.relname AS tablename,
  t.seq_scan,
  t.seq_tup_read,
  t.idx_scan,
  t.n_live_tup,

  CASE
    WHEN t.seq_scan = 0
      THEN 'No issue'
    WHEN t.idx_scan = 0
      THEN 'Likely missing index OR predicate not selective'
    WHEN t.seq_tup_read > (t.n_live_tup * 10)
      THEN 'Table small — planner intentionally prefers seq-scan'
    ELSE
      'Investigate filters, stats skew, and misestimation'
  END AS hypothesis,

  'ACTION: Capture query and run EXPLAIN (ANALYZE, BUFFERS).'
  AS next_step

FROM pg_stat_user_tables t;

-- ============================================================================
-- VIEW 6A: Duplicate Index Detector (Exact Structural Match)
-- Purpose:
--   Flags indexes that have identical column definitions and are redundant.
--   If two indexes serve the same purpose, one can be removed safely
--   after workload validation.
-- ============================================================================

DROP VIEW IF EXISTS dbre_duplicate_indexes_exact CASCADE;

CREATE VIEW dbre_duplicate_indexes_exact AS
WITH indexed_cols AS (
  SELECT
    i.oid AS indexrelid,
    i.relname AS index_name,
    t.relname AS table_name,
    n.nspname AS schema_name,
    pg_get_indexdef(i.oid) AS index_def,
    pg_get_expr(idx.indexprs, idx.indrelid) AS expr_cols,
    array_to_string(idx.indkey, ',') AS key_order
  FROM pg_index idx
  JOIN pg_class i   ON i.oid = idx.indexrelid
  JOIN pg_class t   ON t.oid = idx.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','pg_toast')
)
SELECT
  a.schema_name,
  a.table_name,
  a.index_name AS duplicate_index,
  b.index_name AS original_index,
  a.index_def AS duplicate_def,
  b.index_def AS original_def,
  'ACTION: Drop duplicate index after verifying no workload dependency'
  AS recommendation
FROM indexed_cols a
JOIN indexed_cols b
  ON a.table_name = b.table_name
 AND a.schema_name = b.schema_name
 AND a.index_name <> b.index_name
 AND a.key_order = b.key_order
 AND COALESCE(a.expr_cols,'') = COALESCE(b.expr_cols,'')
ORDER BY schema_name, table_name;

-- ============================================================================



-- ============================================================================
-- VIEW 6B: Functional Duplicate / Subset Index Detector
-- Purpose:
--   Detects cases where:
--     • idx_A = (col1, col2)
--     • idx_B = (col1)
--   -> idx_B is fully contained inside idx_A and may be removable.
--
--   This is a **staff-level heuristic tool** — NOT an auto-drop rule.
--   Verify by:
--     1) Checking pg_stat_user_indexes usage
--     2) Validating query plans
-- ============================================================================

DROP VIEW IF EXISTS dbre_duplicate_indexes_subset CASCADE;

CREATE VIEW dbre_duplicate_indexes_subset AS
WITH index_cols AS (
  SELECT
    i.oid,
    i.relname AS index_name,
    t.relname AS table_name,
    n.nspname AS schema_name,
    unnest(idx.indkey) AS col_pos,
    row_number() OVER (PARTITION BY i.oid ORDER BY ordinality) AS col_order
  FROM pg_index idx
  JOIN pg_class i   ON i.oid = idx.indexrelid
  JOIN pg_class t   ON t.oid = idx.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  CROSS JOIN LATERAL unnest(idx.indkey) WITH ORDINALITY
  WHERE n.nspname NOT IN ('pg_catalog','pg_toast')
),
index_groups AS (
  SELECT
    oid,
    schema_name,
    table_name,
    index_name,
    array_agg(col_pos ORDER BY col_order) AS cols
  FROM index_cols
  GROUP BY oid, schema_name, table_name, index_name
)
SELECT
  a.schema_name,
  a.table_name,
  a.index_name AS superset_index,
  b.index_name AS redundant_subset_index,
  a.cols AS superset_cols,
  b.cols AS subset_cols,
  'ACTION: Consider dropping subset index — validate workload first'
  AS recommendation
FROM index_groups a
JOIN index_groups b
  ON a.schema_name = b.schema_name
 AND a.table_name = b.table_name
 AND a.index_name <> b.index_name
 AND b.cols <@ a.cols      -- subset operator
ORDER BY schema_name, table_name;

-- ============================================================================
-- END OF FILE
-- ============================================================================




