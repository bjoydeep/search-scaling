#!/bin/bash
# db-collect.sh
# Collects all Layer 1-6 diagnostic data from the search-postgres pod.
# Run AFTER db-reset.sh and a 30-60 minute soak period under normal load.
#
# Output: ./db-output/<timestamp>/ directory with one file per query.
#
# Usage: ./db-collect.sh [namespace]
# Default namespace: open-cluster-management

set -euo pipefail

NS=${1:-open-cluster-management}
POD=$(kubectl get pod -n "$NS" -l name=search-postgres --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD" ]]; then
  echo "ERROR: No running search-postgres pod found in namespace $NS"
  exit 1
fi

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="./db-output/$TIMESTAMP"
mkdir -p "$OUTDIR"

echo "============================================"
echo "  ACM Search DB — Diagnostic Data Collect"
echo "============================================"
echo "Pod:       $POD"
echo "Namespace: $NS"
echo "Time:      $TIMESTAMP"
echo "Output:    $OUTDIR"
echo ""

# Helper — runs a psql query and saves output to a file, prints progress
collect() {
  local label=$1
  local filename=$2
  local query=$3
  echo ">>> $label..."
  {
    echo "-- Query collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "-- Pod: $POD"
    echo "-- $label"
    echo ""
    kubectl exec -n "$NS" "$POD" -- psql -d search -U searchuser \
      --pset="footer=off" -P "border=2" -c "$query"
  } > "$OUTDIR/$filename" 2>&1
  echo "    Saved → $OUTDIR/$filename"
}

# ─────────────────────────────────────────────────────────────────
# LAYER 1 — Query Load Distribution
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 1a — Top queries by total DB time (pg_stat_statements)" \
  "layer1a_top_queries_by_total_time.txt" \
  "SELECT
     round(total_exec_time::numeric, 2)                                              AS total_ms,
     calls,
     round(mean_exec_time::numeric, 2)                                               AS avg_ms,
     round(stddev_exec_time::numeric, 2)                                             AS stddev_ms,
     round((total_exec_time / sum(total_exec_time) OVER ())::numeric * 100, 1)      AS pct_of_db,
     rows,
     left(query, 150)                                                                AS query
   FROM pg_stat_statements
   ORDER BY total_exec_time DESC
   LIMIT 20;"

collect \
  "Layer 1b — High-frequency queries (call count)" \
  "layer1b_high_frequency_queries.txt" \
  "SELECT
     calls,
     round(mean_exec_time::numeric, 2)   AS avg_ms,
     round(total_exec_time::numeric, 2)  AS total_ms,
     rows,
     left(query, 150)                    AS query
   FROM pg_stat_statements
   WHERE calls > 50
   ORDER BY calls DESC
   LIMIT 20;"

collect \
  "Layer 1c — Write queries (INSERT/UPDATE/DELETE/UPSERT)" \
  "layer1c_write_queries.txt" \
  "SELECT
     calls,
     round(mean_exec_time::numeric, 2)   AS avg_ms,
     round(total_exec_time::numeric, 2)  AS total_ms,
     rows,
     left(query, 150)                    AS query
   FROM pg_stat_statements
   WHERE query ~* '(INSERT|UPDATE|DELETE|UPSERT)'
   ORDER BY total_exec_time DESC
   LIMIT 15;"

collect \
  "Layer 1d — Slowest individual queries (avg latency)" \
  "layer1d_slowest_avg_queries.txt" \
  "SELECT
     calls,
     round(mean_exec_time::numeric, 2)   AS avg_ms,
     round(max_exec_time::numeric, 2)    AS max_ms,
     round(stddev_exec_time::numeric, 2) AS stddev_ms,
     left(query, 150)                    AS query
   FROM pg_stat_statements
   WHERE calls > 5
   ORDER BY mean_exec_time DESC
   LIMIT 15;"

# ─────────────────────────────────────────────────────────────────
# LAYER 2 — Wait Event Snapshot
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 2a — Current wait events (point-in-time snapshot)" \
  "layer2a_wait_events_snapshot.txt" \
  "SELECT
     wait_event_type,
     wait_event,
     state,
     count(*)              AS sessions,
     left(query, 100)      AS query
   FROM pg_stat_activity
   WHERE state != 'idle'
   GROUP BY 1, 2, 3, 5
   ORDER BY 4 DESC;"

collect \
  "Layer 2b — All connections by state" \
  "layer2b_connections_by_state.txt" \
  "SELECT
     count(*) FILTER (WHERE state = 'active')                AS active,
     count(*) FILTER (WHERE state = 'idle')                  AS idle,
     count(*) FILTER (WHERE state = 'idle in transaction')   AS idle_in_txn,
     count(*) FILTER (WHERE state = 'idle in transaction (aborted)') AS idle_aborted,
     count(*)                                                AS total,
     (SELECT setting::int FROM pg_settings
      WHERE name = 'max_connections')                        AS max_connections
   FROM pg_stat_activity
   WHERE datname = 'search';"

collect \
  "Layer 2c — Long-running active queries" \
  "layer2c_long_running_queries.txt" \
  "SELECT
     pid,
     now() - query_start              AS running_for,
     wait_event_type,
     wait_event,
     state,
     left(query, 120)                 AS query
   FROM pg_stat_activity
   WHERE state = 'active'
     AND datname = 'search'
     AND query_start < now() - interval '1 second'
   ORDER BY running_for DESC;"

# ─────────────────────────────────────────────────────────────────
# LAYER 3 — Cache Hit Ratio
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 3a — Database-level cache hit ratio" \
  "layer3a_db_cache_hit.txt" \
  "SELECT
     datname,
     blks_hit,
     blks_read,
     round(blks_hit * 100.0 / nullif(blks_hit + blks_read, 0)::numeric, 2) AS cache_hit_pct,
     temp_files,
     pg_size_pretty(temp_bytes)       AS temp_spill,
     deadlocks
   FROM pg_stat_database
   WHERE datname = 'search';"

collect \
  "Layer 3b — Per-table cache hit ratio" \
  "layer3b_table_cache_hit.txt" \
  "SELECT
     relname,
     heap_blks_hit,
     heap_blks_read,
     round(heap_blks_hit * 100.0 /
       nullif(heap_blks_hit + heap_blks_read, 0)::numeric, 2)              AS table_cache_hit_pct,
     idx_blks_hit,
     idx_blks_read,
     round(idx_blks_hit * 100.0 /
       nullif(idx_blks_hit + idx_blks_read, 0)::numeric, 2)                AS idx_cache_hit_pct
   FROM pg_statio_user_tables
   WHERE schemaname = 'search'
   ORDER BY heap_blks_read DESC;"

# ─────────────────────────────────────────────────────────────────
# LAYER 4 — Table Health (Bloat / Vacuum)
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 4a — Dead tuple accumulation and vacuum lag" \
  "layer4a_table_health.txt" \
  "SELECT
     relname,
     n_live_tup,
     n_dead_tup,
     round(n_dead_tup * 100.0 /
       nullif(n_live_tup + n_dead_tup, 0)::numeric, 1)       AS dead_pct,
     n_mod_since_analyze,
     last_autovacuum,
     last_autoanalyze,
     vacuum_count,
     autovacuum_count,
     pg_size_pretty(pg_total_relation_size('search.' || relname)) AS total_size
   FROM pg_stat_user_tables
   WHERE schemaname = 'search'
   ORDER BY n_dead_tup DESC;"

collect \
  "Layer 4b — Index usage (seq scans vs index scans)" \
  "layer4b_index_usage.txt" \
  "SELECT
     relname,
     seq_scan,
     seq_tup_read,
     idx_scan,
     idx_tup_fetch,
     round(idx_scan * 100.0 /
       nullif(seq_scan + idx_scan, 0)::numeric, 1)            AS idx_scan_pct,
     n_live_tup
   FROM pg_stat_user_tables
   WHERE schemaname = 'search'
   ORDER BY seq_scan DESC;"

collect \
  "Layer 4c — Individual index hit rates" \
  "layer4c_index_hit_rates.txt" \
  "SELECT
     indexrelname,
     relname,
     idx_scan,
     idx_tup_read,
     idx_tup_fetch,
     pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
   FROM pg_stat_user_indexes
   WHERE schemaname = 'search'
   ORDER BY idx_scan DESC;"

# ─────────────────────────────────────────────────────────────────
# LAYER 5 — I/O and Checkpoint Pressure
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 5a — Checkpoint and bgwriter pressure" \
  "layer5a_checkpoint_pressure.txt" \
  "SELECT
     checkpoints_timed,
     checkpoints_req,
     round(checkpoint_write_time / 1000)    AS checkpoint_write_s,
     round(checkpoint_sync_time / 1000)     AS checkpoint_sync_s,
     buffers_checkpoint,
     buffers_clean,
     buffers_backend,
     buffers_alloc,
     round(buffers_backend * 100.0 /
       nullif(buffers_checkpoint + buffers_clean + buffers_backend, 0)::numeric, 1)
                                            AS backend_write_pct
   FROM pg_stat_bgwriter;"

# ─────────────────────────────────────────────────────────────────
# LAYER 6 — Current Settings
# ─────────────────────────────────────────────────────────────────
collect \
  "Layer 6a — Key PostgreSQL runtime settings" \
  "layer6a_pg_settings.txt" \
  "SELECT name, setting, unit, source
   FROM pg_settings
   WHERE name IN (
     'shared_buffers', 'effective_cache_size', 'work_mem',
     'maintenance_work_mem', 'max_connections', 'max_parallel_workers',
     'max_parallel_workers_per_gather', 'max_worker_processes',
     'checkpoint_timeout', 'checkpoint_completion_target',
     'autovacuum_vacuum_scale_factor', 'autovacuum_analyze_scale_factor',
     'autovacuum_vacuum_cost_delay', 'random_page_cost',
     'effective_io_concurrency', 'statement_timeout',
     'shared_preload_libraries', 'pg_stat_statements.track',
     'wal_buffers', 'max_wal_size', 'log_min_duration_statement'
   )
   ORDER BY name;"

collect \
  "Layer 6b — Table and index sizes" \
  "layer6b_table_sizes.txt" \
  "SELECT
     relname,
     pg_size_pretty(pg_relation_size('search.' || relname))           AS table_size,
     pg_size_pretty(pg_indexes_size('search.' || relname))            AS indexes_size,
     pg_size_pretty(pg_total_relation_size('search.' || relname))     AS total_size,
     n_live_tup                                                        AS live_rows
   FROM pg_stat_user_tables
   WHERE schemaname = 'search'
   ORDER BY pg_total_relation_size('search.' || relname) DESC;"

# ─────────────────────────────────────────────────────────────────
# SUMMARY FILE
# ─────────────────────────────────────────────────────────────────
{
  echo "ACM Search PostgreSQL Diagnostic Collection"
  echo "==========================================="
  echo "Collected:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Pod:        $POD"
  echo "Namespace:  $NS"
  echo "Output dir: $OUTDIR"
  echo ""
  echo "Files collected:"
  ls -1 "$OUTDIR"/*.txt
  echo ""
  echo "Quick reference — key questions each file answers:"
  echo ""
  echo "  layer1a — Which query owns the most total DB time?"
  echo "  layer1b — Which query fires most frequently?"
  echo "  layer1c — What is the write load from the indexer?"
  echo "  layer1d — What are the slowest individual queries?"
  echo "  layer2a — What are queries waiting on right now?"
  echo "  layer2b — Is the connection pool saturated?"
  echo "  layer2c — Are any queries running unusually long?"
  echo "  layer3a — Is data being served from memory or disk? (target: >99%)"
  echo "  layer3b — Which table is causing the most disk reads?"
  echo "  layer4a — Is dead tuple bloat slowing all queries? (target: dead_pct <5%)"
  echo "  layer4b — Are index scans being used or is it all seq scans?"
  echo "  layer4c — Which indexes are actually being used?"
  echo "  layer5a — Is checkpoint I/O causing write spikes?"
  echo "  layer6a — What are the active PostgreSQL settings?"
  echo "  layer6b — How big are the tables and indexes?"
} > "$OUTDIR/00_summary.txt"

echo ""
echo "============================================"
echo "  Collection complete: $OUTDIR"
echo "  $(ls "$OUTDIR"/*.txt | wc -l) files saved."
echo ""
echo "  Start analysis with: cat $OUTDIR/00_summary.txt"
echo "============================================"
