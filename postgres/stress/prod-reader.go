/*
================================================================================
PRODUCTION-GRADE POSTGRESQL READ WORKLOAD SIMULATOR v2
================================================================================
Purpose: Simulate realistic OLTP + Analytics workload with plan monitoring

NEW FEATURES:
- Zipfian distribution for realistic access patterns (80/20 rule)
- Query plan change detection and alerting
- Connection burst mode testing
- Cache hit rate tracking
- Buffer pool analysis

Usage:
    go run read_workload.go -duration=5m -sessions=25 -workload=mixed
    go run read_workload.go -duration=1m -sessions=25 -workload=mixed -burst=100
================================================================================
*/

package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"math"
	"math/rand"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ============================================================================
// CONFIGURATION
// ============================================================================

type Config struct {
	DBConnString     string
	TableName        string
	SessionCount     int
	BurstSessions    int  // For burst mode testing
	Duration         time.Duration
	WorkloadType     string
	ReportInterval   time.Duration
	
	// Workload distribution
	TotalRows        int64  // Total rows in table (for ID generation)
	TopCustomerPct   float64 // Top X% of customers for hot spot simulation
	
	// Plan monitoring
	PlanCheckEnabled bool
	PlanCheckInterval time.Duration
}

var config = Config{
	DBConnString:      "postgres://dbre_kc:TJd9uj1aCnSkNFGiYjcqbcdefCUa5ZOuA@redacted:5432/avro",
	TableName:         "financial_transactions",
	SessionCount:      25,
	BurstSessions:     0,  // Set via -burst flag
	Duration:          5 * time.Minute,
	WorkloadType:      "mixed",
	ReportInterval:    10 * time.Second,
	TotalRows:         5_000_000,
	TopCustomerPct:    0.20, // Top 20% of customers
	PlanCheckEnabled:  true,
	PlanCheckInterval: 30 * time.Second,
}

// ============================================================================
// ZIPFIAN DISTRIBUTION for Realistic Access Patterns
// ============================================================================

type ZipfGenerator struct {
	n     int64   // Number of items
	s     float64 // Skew parameter (1.0 = standard Zipf)
	v     float64 // Normalization constant
	mu    sync.Mutex
	rand  *rand.Rand
}

func NewZipfGenerator(n int64, s float64) *ZipfGenerator {
	zg := &ZipfGenerator{
		n:    n,
		s:    s,
		rand: rand.New(rand.NewSource(time.Now().UnixNano())),
	}
	
	// Calculate normalization constant
	zg.v = 0
	for i := int64(1); i <= n; i++ {
		zg.v += 1.0 / math.Pow(float64(i), s)
	}
	zg.v = 1.0 / zg.v
	
	return zg
}

func (zg *ZipfGenerator) Next() int64 {
	zg.mu.Lock()
	defer zg.mu.Unlock()
	
	// Inverse transform sampling
	r := zg.rand.Float64()
	sum := 0.0
	
	for i := int64(1); i <= zg.n; i++ {
		sum += zg.v / math.Pow(float64(i), zg.s)
		if sum >= r {
			return i
		}
	}
	
	return zg.n
}

// ============================================================================
// ID GENERATORS (Realistic Distribution)
// ============================================================================

type IDGenerator struct {
	// For hot customer access (Zipfian)
	customerZipf *ZipfGenerator
	
	// For transaction IDs (uniform within bounds)
	minTxnID int64
	maxTxnID int64
	
	// For account IDs (Zipfian with different skew)
	accountZipf *ZipfGenerator
}

func NewIDGenerator(totalRows int64) *IDGenerator {
	// Top 20% of customers get 80% of traffic
	totalCustomers := int64(100000) // Based on your data generator
	
	return &IDGenerator{
		customerZipf: NewZipfGenerator(totalCustomers, 1.07), // 80/20 distribution
		accountZipf:  NewZipfGenerator(1000000, 0.9),         // Slightly less skewed
		minTxnID:     1,
		maxTxnID:     totalRows,
	}
}

func (ig *IDGenerator) GetCustomerID() int64 {
	return ig.customerZipf.Next()
}

func (ig *IDGenerator) GetAccountID() int64 {
	return ig.accountZipf.Next()
}

func (ig *IDGenerator) GetTransactionID() int64 {
	// Uniform random within valid range
	return ig.minTxnID + rand.Int63n(ig.maxTxnID-ig.minTxnID)
}

// Global ID generator
var idGen *IDGenerator

// ============================================================================
// QUERY PLAN TRACKING
// ============================================================================

type QueryPlan struct {
	QueryName    string
	PlanHash     string
	PlanText     string
	FirstSeen    time.Time
	LastSeen     time.Time
	ExecutionCount int64
	AvgCost      float64
}

type PlanMonitor struct {
	plans map[string]*QueryPlan // Key: queryName + planHash
	mu    sync.RWMutex
}

func NewPlanMonitor() *PlanMonitor {
	return &PlanMonitor{
		plans: make(map[string]*QueryPlan),
	}
}

func (pm *PlanMonitor) RecordPlan(queryName, planText string, cost float64) {
	// Create hash of plan structure (ignore costs/actual rows)
	planHash := hashPlanStructure(planText)
	key := fmt.Sprintf("%s:%s", queryName, planHash)
	
	pm.mu.Lock()
	defer pm.mu.Unlock()
	
	if plan, exists := pm.plans[key]; exists {
		plan.LastSeen = time.Now()
		plan.ExecutionCount++
		plan.AvgCost = (plan.AvgCost*float64(plan.ExecutionCount-1) + cost) / float64(plan.ExecutionCount)
	} else {
		pm.plans[key] = &QueryPlan{
			QueryName:      queryName,
			PlanHash:       planHash,
			PlanText:       planText,
			FirstSeen:      time.Now(),
			LastSeen:       time.Now(),
			ExecutionCount: 1,
			AvgCost:        cost,
		}
	}
}

func (pm *PlanMonitor) DetectChanges() []string {
	pm.mu.RLock()
	defer pm.mu.RUnlock()
	
	// Group plans by query name
	queryPlans := make(map[string][]*QueryPlan)
	for _, plan := range pm.plans {
		queryPlans[plan.QueryName] = append(queryPlans[plan.QueryName], plan)
	}
	
	var alerts []string
	for queryName, plans := range queryPlans {
		if len(plans) > 1 {
			// Multiple plans detected for same query!
			alert := fmt.Sprintf("⚠️  PLAN CHANGE DETECTED: %s has %d different plans", 
				queryName, len(plans))
			alerts = append(alerts, alert)
			
			// Sort by first seen
			sort.Slice(plans, func(i, j int) bool {
				return plans[i].FirstSeen.Before(plans[j].FirstSeen)
			})
			
			for i, plan := range plans {
				alert = fmt.Sprintf("    Plan #%d (hash: %.8s): Cost=%.2f, Executions=%d, First=%s, Last=%s",
					i+1, plan.PlanHash, plan.AvgCost, plan.ExecutionCount,
					plan.FirstSeen.Format("15:04:05"), plan.LastSeen.Format("15:04:05"))
				alerts = append(alerts, alert)
			}
		}
	}
	
	return alerts
}

func (pm *PlanMonitor) GetSummary() map[string]int {
	pm.mu.RLock()
	defer pm.mu.RUnlock()
	
	summary := make(map[string]int)
	for _, plan := range pm.plans {
		summary[plan.QueryName]++
	}
	
	return summary
}

func hashPlanStructure(planText string) string {
	// Extract just the node types and join types, ignore costs/rows
	// This is simplified - in production you'd parse the JSON plan
	lines := strings.Split(planText, "\n")
	var structure []string
	
	for _, line := range lines {
		// Extract node types (Index Scan, Seq Scan, etc.)
		if strings.Contains(line, "Scan") || strings.Contains(line, "Join") || 
		   strings.Contains(line, "Aggregate") || strings.Contains(line, "Sort") {
			// Remove costs and row estimates
			cleaned := strings.Split(line, "(cost=")[0]
			structure = append(structure, strings.TrimSpace(cleaned))
		}
	}
	
	combined := strings.Join(structure, "|")
	hash := md5.Sum([]byte(combined))
	return hex.EncodeToString(hash[:])
}

// Global plan monitor
var planMonitor *PlanMonitor

// ============================================================================
// QUERY DEFINITIONS
// ============================================================================

type Query struct {
	Name        string
	SQL         string
	Type        string
	Weight      int
	Description string
	ExplainSQL  string // For plan capture
}

var queries = []Query{
	// ========================================================================
	// OLTP QUERIES
	// ========================================================================
	{
		Name:        "pk_lookup",
		Type:        "oltp",
		Weight:      20,
		Description: "Primary key lookup",
		SQL: `SELECT transaction_id, external_txn_id, amount, currency, transaction_status
              FROM financial_transactions 
              WHERE transaction_id = $1`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE) 
                     SELECT transaction_id, external_txn_id, amount, currency, transaction_status
                     FROM financial_transactions WHERE transaction_id = $1`,
	},
	{
		Name:        "customer_recent",
		Type:        "oltp",
		Weight:      15,
		Description: "Recent customer transactions (hot customers)",
		SQL: `SELECT transaction_id, amount, transaction_type, transaction_date, transaction_status
              FROM financial_transactions 
              WHERE customer_id = $1 
              AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
              ORDER BY transaction_date DESC 
              LIMIT 20`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT transaction_id, amount, transaction_type, transaction_date, transaction_status
                     FROM financial_transactions 
                     WHERE customer_id = $1 AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
                     ORDER BY transaction_date DESC LIMIT 20`,
	},
	{
		Name:        "account_status_check",
		Type:        "oltp",
		Weight:      15,
		Description: "Pending transactions by account",
		SQL: `SELECT COUNT(*) as pending_count, COALESCE(SUM(amount), 0) as pending_amount
              FROM financial_transactions 
              WHERE account_id = $1 
              AND transaction_status = 'pending'`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT COUNT(*) as pending_count, COALESCE(SUM(amount), 0) as pending_amount
                     FROM financial_transactions 
                     WHERE account_id = $1 AND transaction_status = 'pending'`,
	},
	{
		Name:        "high_value_recent",
		Type:        "oltp",
		Weight:      10,
		Description: "High value transactions for review",
		SQL: `SELECT transaction_id, customer_id, amount, risk_score
              FROM financial_transactions 
              WHERE amount > 10000
              AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
              ORDER BY amount DESC 
              LIMIT 100`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT transaction_id, customer_id, amount, risk_score
                     FROM financial_transactions 
                     WHERE amount > 10000 AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
                     ORDER BY amount DESC LIMIT 100`,
	},
	{
		Name:        "flagged_transactions",
		Type:        "oltp",
		Weight:      10,
		Description: "Flagged transactions for fraud review",
		SQL: `SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
              FROM financial_transactions 
              WHERE is_flagged = true 
              AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
              ORDER BY risk_score DESC 
              LIMIT 50`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT transaction_id, customer_id, amount, risk_score, fraud_check_status
                     FROM financial_transactions 
                     WHERE is_flagged = true AND transaction_date >= CURRENT_DATE - INTERVAL '7 days'
                     ORDER BY risk_score DESC LIMIT 50`,
	},

	// ========================================================================
	// ANALYTICS QUERIES
	// ========================================================================
	{
		Name:        "daily_volume",
		Type:        "analytics",
		Weight:      8,
		Description: "Daily aggregates",
		SQL: `SELECT 
                transaction_date,
                COUNT(*) as txn_count,
                SUM(amount_usd) as total_volume,
                AVG(amount_usd) as avg_amount,
                COUNT(DISTINCT customer_id) as unique_customers
              FROM financial_transactions 
              WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
              AND is_deleted = false
              GROUP BY transaction_date
              ORDER BY transaction_date DESC`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT transaction_date, COUNT(*) as txn_count, SUM(amount_usd) as total_volume,
                     AVG(amount_usd) as avg_amount, COUNT(DISTINCT customer_id) as unique_customers
                     FROM financial_transactions 
                     WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days' AND is_deleted = false
                     GROUP BY transaction_date ORDER BY transaction_date DESC`,
	},
	{
		Name:        "high_risk_analysis",
		Type:        "analytics",
		Weight:      6,
		Description: "Risk analysis by status",
		SQL: `SELECT 
                fraud_check_status,
                COUNT(*) as txn_count,
                SUM(amount_usd) as total_amount,
                AVG(risk_score) as avg_risk_score,
                COUNT(DISTINCT customer_id) as affected_customers
              FROM financial_transactions 
              WHERE risk_score > 70
              AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
              GROUP BY fraud_check_status
              ORDER BY txn_count DESC`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT fraud_check_status, COUNT(*) as txn_count, SUM(amount_usd) as total_amount,
                     AVG(risk_score) as avg_risk_score, COUNT(DISTINCT customer_id) as affected_customers
                     FROM financial_transactions 
                     WHERE risk_score > 70 AND transaction_date >= CURRENT_DATE - INTERVAL '30 days'
                     GROUP BY fraud_check_status ORDER BY txn_count DESC`,
	},
	{
		Name:        "payment_method_trends",
		Type:        "analytics",
		Weight:      5,
		Description: "Payment method weekly trends",
		SQL: `SELECT 
                payment_method,
                DATE_TRUNC('week', transaction_date) as week,
                COUNT(*) as txn_count,
                SUM(amount_usd) as volume
              FROM financial_transactions 
              WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
              GROUP BY payment_method, DATE_TRUNC('week', transaction_date)
              ORDER BY week DESC, txn_count DESC
              LIMIT 200`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT payment_method, DATE_TRUNC('week', transaction_date) as week,
                     COUNT(*) as txn_count, SUM(amount_usd) as volume
                     FROM financial_transactions 
                     WHERE transaction_date >= CURRENT_DATE - INTERVAL '90 days'
                     GROUP BY payment_method, DATE_TRUNC('week', transaction_date)
                     ORDER BY week DESC, txn_count DESC LIMIT 200`,
	},
	{
		Name:        "regional_performance",
		Type:        "analytics",
		Weight:      4,
		Description: "Regional aggregates",
		SQL: `SELECT 
                country_code,
                region,
                COUNT(*) as txn_count,
                SUM(amount_usd) as total_volume,
                COUNT(DISTINCT customer_id) as unique_customers
              FROM financial_transactions 
              WHERE transaction_date >= CURRENT_DATE - INTERVAL '60 days'
              GROUP BY country_code, region
              ORDER BY total_volume DESC`,
		ExplainSQL: `EXPLAIN (FORMAT TEXT, COSTS TRUE)
                     SELECT country_code, region, COUNT(*) as txn_count, SUM(amount_usd) as total_volume,
                     COUNT(DISTINCT customer_id) as unique_customers
                     FROM financial_transactions 
                     WHERE transaction_date >= CURRENT_DATE - INTERVAL '60 days'
                     GROUP BY country_code, region ORDER BY total_volume DESC`,
	},
}

// ============================================================================
// METRICS TRACKING
// ============================================================================

type Metrics struct {
	queryMetrics map[string]*QueryMetrics
	cacheStats   *CacheStats
	totalQueries int64
	totalErrors  int64
	startTime    time.Time
	poolStats    []PoolSnapshot
	mu           sync.RWMutex
}

type QueryMetrics struct {
	Name           string
	ExecutionCount int64
	ErrorCount     int64
	Latencies      []time.Duration
	TotalDuration  time.Duration
	mu             sync.Mutex
}

type CacheStats struct {
	cacheHits   int64
	cacheMisses int64
	bufferHits  int64
	bufferReads int64
}

type PoolSnapshot struct {
	Timestamp            time.Time
	AcquireCount         int64
	AcquireDuration      time.Duration
	AcquiredConns        int32
	CanceledAcquireCount int64
	EmptyAcquireCount    int64
	IdleConns            int32
	TotalConns           int32
}

func NewMetrics() *Metrics {
	m := &Metrics{
		queryMetrics: make(map[string]*QueryMetrics),
		cacheStats:   &CacheStats{},
		startTime:    time.Now(),
		poolStats:    make([]PoolSnapshot, 0),
	}
	
	for _, q := range queries {
		m.queryMetrics[q.Name] = &QueryMetrics{
			Name:      q.Name,
			Latencies: make([]time.Duration, 0, 10000),
		}
	}
	
	return m
}

func (m *Metrics) RecordQuery(queryName string, duration time.Duration, err error) {
	atomic.AddInt64(&m.totalQueries, 1)
	
	m.mu.Lock()
	qm := m.queryMetrics[queryName]
	m.mu.Unlock()
	
	qm.mu.Lock()
	defer qm.mu.Unlock()
	
	qm.ExecutionCount++
	qm.TotalDuration += duration
	qm.Latencies = append(qm.Latencies, duration)
	
	if err != nil {
		qm.ErrorCount++
		atomic.AddInt64(&m.totalErrors, 1)
	}
}

func (m *Metrics) UpdateCacheStats(ctx context.Context, pool *pgxpool.Pool) {
	var heapBlksRead, heapBlksHit, idxBlksRead, idxBlksHit int64
	
	err := pool.QueryRow(ctx, `
		SELECT 
			heap_blks_read, heap_blks_hit,
			idx_blks_read, idx_blks_hit
		FROM pg_statio_user_tables
		WHERE relname = $1
	`, config.TableName).Scan(&heapBlksRead, &heapBlksHit, &idxBlksRead, &idxBlksHit)
	
	if err == nil {
		atomic.StoreInt64(&m.cacheStats.bufferReads, heapBlksRead+idxBlksRead)
		atomic.StoreInt64(&m.cacheStats.bufferHits, heapBlksHit+idxBlksHit)
	}
}

func (m *Metrics) GetCacheHitRatio() float64 {
	hits := atomic.LoadInt64(&m.cacheStats.bufferHits)
	reads := atomic.LoadInt64(&m.cacheStats.bufferReads)
	total := hits + reads
	
	if total == 0 {
		return 0
	}
	
	return float64(hits) / float64(total) * 100
}

func (m *Metrics) RecordPoolStats(pool *pgxpool.Pool) {
	stat := pool.Stat()
	
	snapshot := PoolSnapshot{
		Timestamp:            time.Now(),
		AcquireCount:         stat.AcquireCount(),
		AcquireDuration:      stat.AcquireDuration(),
		AcquiredConns:        stat.AcquiredConns(),
		CanceledAcquireCount: stat.CanceledAcquireCount(),
		EmptyAcquireCount:    stat.EmptyAcquireCount(),
		IdleConns:            stat.IdleConns(),
		TotalConns:           stat.TotalConns(),
	}
	
	m.mu.Lock()
	m.poolStats = append(m.poolStats, snapshot)
	m.mu.Unlock()
}

func (m *Metrics) PrintReport() {
	m.mu.RLock()
	defer m.mu.RUnlock()
	
	duration := time.Since(m.startTime)
	
	fmt.Println("\n" + strings.Repeat("=", 110))
	fmt.Println("📊 WORKLOAD SIMULATION REPORT")
	fmt.Println(strings.Repeat("=", 110))
	
	fmt.Printf("\n⏱️  Overall Performance:\n")
	fmt.Printf("   Duration:          %v\n", duration.Round(time.Second))
	fmt.Printf("   Total Queries:     %d\n", m.totalQueries)
	fmt.Printf("   Total Errors:      %d (%.2f%%)\n", m.totalErrors, 
		float64(m.totalErrors)/float64(m.totalQueries)*100)
	fmt.Printf("   Overall QPS:       %.2f queries/sec\n", 
		float64(m.totalQueries)/duration.Seconds())
	fmt.Printf("   Cache Hit Ratio:   %.2f%%\n", m.GetCacheHitRatio())
	
	fmt.Printf("\n📈 Per-Query Performance:\n")
	fmt.Printf("%-30s %10s %10s %10s %10s %10s %10s\n",
		"Query", "Count", "Errors", "Avg(ms)", "p50(ms)", "p95(ms)", "p99(ms)")
	fmt.Println(strings.Repeat("-", 110))
	
	type queryStats struct {
		name  string
		count int64
	}
	var sortedQueries []queryStats
	for name, qm := range m.queryMetrics {
		sortedQueries = append(sortedQueries, queryStats{name, qm.ExecutionCount})
	}
	sort.Slice(sortedQueries, func(i, j int) bool {
		return sortedQueries[i].count > sortedQueries[j].count
	})
	
	for _, qs := range sortedQueries {
		qm := m.queryMetrics[qs.name]
		qm.mu.Lock()
		
		if qm.ExecutionCount == 0 {
			qm.mu.Unlock()
			continue
		}
		
		latencies := make([]time.Duration, len(qm.Latencies))
		copy(latencies, qm.Latencies)
		sort.Slice(latencies, func(i, j int) bool {
			return latencies[i] < latencies[j]
		})
		
		avg := qm.TotalDuration.Milliseconds() / int64(qm.ExecutionCount)
		p50 := latencies[len(latencies)*50/100].Milliseconds()
		p95 := latencies[len(latencies)*95/100].Milliseconds()
		p99 := latencies[len(latencies)*99/100].Milliseconds()
		
		fmt.Printf("%-30s %10d %10d %10d %10d %10d %10d\n",
			qm.Name, qm.ExecutionCount, qm.ErrorCount, avg, p50, p95, p99)
		
		qm.mu.Unlock()
	}
	
	// Query Plan Summary
	fmt.Printf("\n🔍 Query Plan Summary:\n")
	planSummary := planMonitor.GetSummary()
	for queryName, planCount := range planSummary {
		if planCount > 1 {
			fmt.Printf("   ⚠️  %s: %d different plans detected\n", queryName, planCount)
		} else {
			fmt.Printf("   ✅ %s: Stable plan\n", queryName)
		}
	}
	
	// Connection Pool Stats
	if len(m.poolStats) > 0 {
		fmt.Printf("\n🔌 Connection Pool Statistics:\n")
		lastStat := m.poolStats[len(m.poolStats)-1]
		
		fmt.Printf("   Total Connections:    %d\n", lastStat.TotalConns)
		fmt.Printf("   Idle Connections:     %d\n", lastStat.IdleConns)
		fmt.Printf("   Acquired:             %d\n", lastStat.AcquiredConns)
		fmt.Printf("   Total Acquires:       %d\n", lastStat.AcquireCount)
		
		if lastStat.AcquireCount > 0 {
			avgAcquire := lastStat.AcquireDuration.Microseconds() / lastStat.AcquireCount
			fmt.Printf("   Avg Acquire Time:     %d µs\n", avgAcquire)
		}
		
		if lastStat.EmptyAcquireCount > 0 {
			fmt.Printf("   ⚠️  Empty Acquires:     %d (POOL EXHAUSTION!)\n", lastStat.EmptyAcquireCount)
		}
		if lastStat.CanceledAcquireCount > 0 {
			fmt.Printf("   ⚠️  Canceled Acquires:  %d\n", lastStat.CanceledAcquireCount)
		}
	}
	
	fmt.Println(strings.Repeat("=", 110))
}

// ============================================================================
// CONNECTION POOL SETUP
// ============================================================================

func initConnectionPool(ctx context.Context, connString string, maxConns int) (*pgxpool.Pool, error) {
	poolConfig, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}
	
	poolConfig.MaxConns = int32(maxConns)
	poolConfig.MinConns = int32(maxConns / 4)
	poolConfig.MaxConnLifetime = 1 * time.Hour
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	poolConfig.HealthCheckPeriod = 1 * time.Minute
	
	poolConfig.ConnConfig.RuntimeParams = map[string]string{
		"application_name":     "read_workload_simulator",
		"statement_timeout":    "120000", // 2 minutes for analytics
		"idle_in_transaction_session_timeout": "60000",
		"work_mem":             "256MB",  // Increase for GROUP BY/sorts
		"max_parallel_workers_per_gather": "4", // Enable parallel query
	}
	
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create pool: %w", err)
	}
	
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}
	
	return pool, nil
}

// ============================================================================
// WORKLOAD EXECUTION
// ============================================================================

func selectQuery(workloadType string) Query {
	var candidateQueries []Query
	
	switch workloadType {
	case "oltp":
		for _, q := range queries {
			if q.Type == "oltp" {
				candidateQueries = append(candidateQueries, q)
			}
		}
	case "analytics":
		for _, q := range queries {
			if q.Type == "analytics" {
				candidateQueries = append(candidateQueries, q)
			}
		}
	case "mixed":
		if rand.Intn(100) < 70 {
			for _, q := range queries {
				if q.Type == "oltp" {
					candidateQueries = append(candidateQueries, q)
				}
			}
		} else {
			for _, q := range queries {
				if q.Type == "analytics" {
					candidateQueries = append(candidateQueries, q)
				}
			}
		}
	}
	
	totalWeight := 0
	for _, q := range candidateQueries {
		totalWeight += q.Weight
	}
	
	r := rand.Intn(totalWeight)
	cumWeight := 0
	for _, q := range candidateQueries {
		cumWeight += q.Weight
		if r < cumWeight {
			return q
		}
	}
	
	return candidateQueries[0]
}

func generateQueryParams(query Query) []interface{} {
	switch query.Name {
	case "pk_lookup":
		return []interface{}{idGen.GetTransactionID()}
	case "customer_recent":
		return []interface{}{idGen.GetCustomerID()}
	case "account_status_check":
		return []interface{}{idGen.GetAccountID()}
	default:
		return []interface{}{}
	}
}

func executeQuery(ctx context.Context, pool *pgxpool.Pool, query Query, metrics *Metrics) {
	params := generateQueryParams(query)
	
	start := time.Now()
	rows, err := pool.Query(ctx, query.SQL, params...)
	duration := time.Since(start)
	
	if err != nil {
		metrics.RecordQuery(query.Name, duration, err)
		log.Printf("Query %s failed: %v", query.Name, err)
		return
	}
	defer rows.Close()
	
	rowCount := 0
	for rows.Next() {
		rowCount++
	}
	
	if err := rows.Err(); err != nil {
		metrics.RecordQuery(query.Name, duration, err)
		return
	}
	
	metrics.RecordQuery(query.Name, duration, nil)
}

func runWorker(ctx context.Context, workerID int, pool *pgxpool.Pool, metrics *Metrics, wg *sync.WaitGroup) {
	defer wg.Done()
	
	for {
		select {
		case <-ctx.Done():
			return
		default:
			query := selectQuery(config.WorkloadType)
			executeQuery(ctx, pool, query, metrics)
			
			// Think time: 0-10ms
			time.Sleep(time.Duration(rand.Intn(10)) * time.Millisecond)
		}
	}
}

// ============================================================================
// PLAN MONITORING
// ============================================================================

func monitorQueryPlans(ctx context.Context, pool *pgxpool.Pool) {
	ticker := time.NewTicker(config.PlanCheckInterval)
	defer ticker.Stop()
	
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			for _, query := range queries {
				if query.ExplainSQL == "" {
					continue
				}
				
				params := generateQueryParams(query)
				rows, err := pool.Query(ctx, query.ExplainSQL, params...)
				if err != nil {
					continue
				}
				
				var planLines []string
				for rows.Next() {
					var line string
					if err := rows.Scan(&line); err == nil {
						planLines = append(planLines, line)
					}
				}
				rows.Close()
				
				if len(planLines) > 0 {
					planText := strings.Join(planLines, "\n")
					
					// Extract cost estimate
					var cost float64
					for _, line := range planLines {
						if strings.Contains(line, "cost=") {
							fmt.Sscanf(line, "%*s (cost=%f", &cost)
							break
						}
					}
					
					planMonitor.RecordPlan(query.Name, planText, cost)
				}
			}
			
			// Check for plan changes
			alerts := planMonitor.DetectChanges()
			if len(alerts) > 0 {
				fmt.Println("\n" + strings.Repeat("!", 80))
				for _, alert := range alerts {
					fmt.Println(alert)
				}
				fmt.Println(strings.Repeat("!", 80) + "\n")
			}
		}
	}
}

// ============================================================================
// PROGRESS MONITORING
// ============================================================================

func monitorProgress(ctx context.Context, pool *pgxpool.Pool, metrics *Metrics) {
	ticker := time.NewTicker(config.ReportInterval)
	defer ticker.Stop()
	
	lastQueries := int64(0)
	lastTime := time.Now()
	
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			currentQueries := atomic.LoadInt64(&metrics.totalQueries)
			currentTime := time.Now()
			
			elapsed := currentTime.Sub(lastTime).Seconds()
			qps := float64(currentQueries-lastQueries) / elapsed
			
			metrics.RecordPoolStats(pool)
			metrics.UpdateCacheStats(ctx, pool)
			
			stat := pool.Stat()
			cacheHit := metrics.GetCacheHitRatio()
			
			fmt.Printf("[%s] QPS: %.0f | Total: %d | Errors: %d | Pool: %d/%d (idle:%d) | Cache: %.1f%%\n",
				time.Now().Format("15:04:05"),
				qps,
				currentQueries,
				atomic.LoadInt64(&metrics.totalErrors),
				stat.AcquiredConns(),
				stat.TotalConns(),
				stat.IdleConns(),
				cacheHit,
			)
			
			lastQueries = currentQueries
			lastTime = currentTime
		}
	}
}

// ============================================================================
// BURST MODE TESTING
// ============================================================================

func runBurstTest(ctx context.Context, pool *pgxpool.Pool, metrics *Metrics) {
	fmt.Printf("\n🚨 BURST MODE: Spiking to %d sessions for 30 seconds...\n", config.BurstSessions)
	
	burstCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	
	var wg sync.WaitGroup
	for i := 0; i < config.BurstSessions; i++ {
		wg.Add(1)
		go runWorker(burstCtx, 1000+i, pool, metrics, &wg)
	}
	
	wg.Wait()
	fmt.Println("✅ Burst test completed")
}

// ============================================================================
// MAIN
// ============================================================================

func main() {
	duration := flag.Duration("duration", 5*time.Minute, "Test duration")
	sessions := flag.Int("sessions", 25, "Number of concurrent sessions")
	burst := flag.Int("burst", 0, "Burst sessions (0 = disabled)")
	workload := flag.String("workload", "mixed", "Workload: oltp, analytics, mixed")
	
	flag.Parse()
	
	config.Duration = *duration
	config.SessionCount = *sessions
	config.BurstSessions = *burst
	config.WorkloadType = *workload
	
	fmt.Println("🚀 PostgreSQL Read Workload Simulator v2")
	fmt.Println(strings.Repeat("=", 110))
	fmt.Printf("Configuration:\n")
	fmt.Printf("   Sessions:       %d\n", config.SessionCount)
	fmt.Printf("   Duration:       %v\n", config.Duration)
	fmt.Printf("   Workload Type:  %s (70%% OLTP, 30%% Analytics)\n", config.WorkloadType)
	fmt.Printf("   Burst Mode:     %s\n", map[bool]string{true: fmt.Sprintf("Enabled (%d sessions)", config.BurstSessions), false: "Disabled"}[config.BurstSessions > 0])
	fmt.Printf("   Table:          %s (%d rows)\n", config.TableName, config.TotalRows)
	fmt.Printf("   Distribution:   Zipfian (80/20 rule for hot customers)\n")
	fmt.Printf("   Plan Tracking:  Enabled (check every %v)\n", config.PlanCheckInterval)
	fmt.Println(strings.Repeat("=", 110))
	
	ctx := context.Background()
	
	// Initialize ID generator with realistic distribution
	idGen = NewIDGenerator(config.TotalRows)
	
	// Initialize plan monitor
	planMonitor = NewPlanMonitor()
	
	pool, err := initConnectionPool(ctx, config.DBConnString, config.SessionCount+10)
	if err != nil {
		log.Fatal("Failed to initialize connection pool:", err)
	}
	defer pool.Close()
	
	fmt.Println("✅ Connected to PostgreSQL")
	
	metrics := NewMetrics()
	
	workloadCtx, cancel := context.WithTimeout(ctx, config.Duration)
	defer cancel()
	
	// Start monitoring goroutines
	go monitorProgress(workloadCtx, pool, metrics)
	go monitorQueryPlans(workloadCtx, pool)
	
	// Start worker goroutines
	var wg sync.WaitGroup
	fmt.Printf("\n🏃 Starting %d worker sessions...\n\n", config.SessionCount)
	
	for i := 0; i < config.SessionCount; i++ {
		wg.Add(1)
		go runWorker(workloadCtx, i, pool, metrics, &wg)
	}
	
	// Run burst test if enabled
	if config.BurstSessions > 0 {
		time.Sleep(30 * time.Second) // Wait 30s before burst
		go runBurstTest(workloadCtx, pool, metrics)
	}
	
	wg.Wait()
	
	metrics.PrintReport()
	
	fmt.Println("\n✅ Workload simulation completed!")
}

/*
================================================================================
USAGE EXAMPLES
================================================================================

1. Standard 70/30 mixed workload:
   go run read_workload.go -duration=5m -sessions=25 -workload=mixed

2. Test connection exhaustion with burst:
   go run read_workload.go -duration=2m -sessions=25 -burst=100 -workload=mixed

3. Pure OLTP with high concurrency:
   go run read_workload.go -duration=5m -sessions=50 -workload=oltp

4. Analytics workload (lower concurrency):
   go run read_workload.go -duration=10m -sessions=10 -workload=analytics

================================================================================
MONITORING TIPS
================================================================================

Watch for these alerts:
- "PLAN CHANGE DETECTED" = Optimizer switching strategies
- "POOL EXHAUSTION" = Need more connections or investigate long queries
- Low cache hit ratio (<90%) = Queries not hitting shared_buffers

Next steps after seeing plan changes:
1. Run ANALYZE on the table
2. Check if statistics are stale
3. Consider pinning plans with pg_hint_plan (if critical)
4. Review work_mem and effective_cache_size settings

================================================================================
*/
