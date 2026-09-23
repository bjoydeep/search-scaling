# PostgreSQL Performance — Analytical Diagnostic Framework
## ACM Search: Indexer + API + PostgreSQL

---

## Step 0 — Enable pg_stat_statements (Do This First)

`pg_stat_statements` is the foundation of all query-level analysis in this framework.
Without it, Layer 1 (query ranking) cannot be run and you are flying blind.
**Do this before any analysis.** It requires one postgres restart.

### What it is

A PostgreSQL extension that tracks execution statistics for every query:
total time, call count, average time, rows returned, temp disk usage.
It is the only way to answer "which query is consuming the most DB time" across
ALL callers — indexer, search-api cache refresh, App Lifecycle, Governance, UI —
without adding instrumentation to any application.

### Setup — use the script

All steps are automated in `enable-pg-stat-statements.sh`. Run it once per cluster:

```bash
./enable-pg-stat-statements.sh [namespace]
# Default namespace: open-cluster-management
```

The script handles everything: checks if already enabled (exits immediately if so),
pauses the operator, patches the configmap, restarts postgres, creates the extension,
makes it permanent in `postgresql-start.sh`, restores the operator, and verifies the
operator did not overwrite the config. Safe to re-run.

**Key facts confirmed by testing (ACM 2.16.x, 2026-09-18):**
- `custom-postgresql.conf` is the designated customization hook — operator does NOT
  overwrite it on reconciliation
- postgres uses `emptyDir` storage — all data wiped on pod restart, repopulates from
  collectors; `custom-postgresql.conf` survives (it lives in the configmap, not data dir)
- `CREATE EXTENSION` must live in `postgresql-start.sh` to survive pod restarts —
  the script adds it there automatically

### Start a clean measurement window

Once enabled, reset stats so you get a clean baseline before analysis:
```bash
./db-reset.sh
# then wait 30-60 minutes under normal load before collecting
```

Then let the system run under **normal production load for 30-60 minutes** before
running any of the Layer 1-6 queries. This captures a representative sample of:
- App Lifecycle GitOps sync (fires every 30s)
- search-api cache refresh (fires every 5min per pod)
- Indexer collector syncs (continuous)
- Any user or Governance queries

Do not reset stats again until you have collected all Layer 1-6 results.

---

## The Core Principle

Every DB performance problem has exactly one root cause category.
The goal of this framework is to place each bottleneck conclusively into one bucket.

```
┌─────────────────────┬──────────────────────────────────────────────────────┐
│ Resource ceiling    │ More RAM / CPU / IOPS solves it proportionally.       │
│                     │ The code and config are fine — just not enough juice. │
├─────────────────────┼──────────────────────────────────────────────────────┤
│ Configuration gap   │ Same hardware, better settings solves it.             │
│                     │ wrong PG params, missing indexes, stale stats, bloat. │
├─────────────────────┼──────────────────────────────────────────────────────┤
│ Query / schema flaw │ No amount of resources or tuning solves it.           │
│                     │ The query or data model is fundamentally wrong.       │
│                     │ Only a code change works.                             │
└─────────────────────┴──────────────────────────────────────────────────────┘
```

**Key test for resource vs code:** If you double resources and throughput improves
less than proportionally, there is a fundamental inefficiency. Resources just make
bad queries run faster — they don't fix the design.

---

## ACM Search Architecture Context

Understanding the write/read contention model is essential before diving into metrics.

```
Managed Clusters                Hub Cluster
────────────────                ──────────────────────────────────────────────────────
Collector 1 ─┐
Collector 2 ─┼──(HTTP/TLS)──▶ Indexer ──(upsert/delete)──▶ PostgreSQL
Collector N ─┘                                                    │
                                                             (select)
                               search-api ───────────────────────┤
                               (per-pod cache, 5min TTL)         │
                                    ▲                             │
                                    │ GraphQL queries             │
                     ┌──────────────┼──────────────┐             │
                     │              │              │              │
              ACM App          ACM Governance   ACM UI      MCP Server
              Lifecycle        (policy list,    (cluster     (LLM/AI
              (resource        compliance       resource     direct DB
              discovery,       queries)         mgmt)        queries)
              topology)
```

**Contention model:**

**Source 1 — Indexer (writes):**
- Continuous write pressure — UPSERTs, DELETEs, edge recomputation
- Triggered by collector sync events, not on a timer

**Source 2 — search-api internal cache refresh (reads):**
- Periodic full-table scans on a 5-minute TTL timer, regardless of user traffic
- Kubernetes probes hit the API every ~30s → probe triggers `PopulateSharedCache` → when
  TTL expires, fires expensive DB queries (even with zero human users)
- With 2 API pods, each with an independent 5-min clock, the DB sees background scans
  roughly every 2.5 minutes

**Source 3 — ACM platform components (reads, continuous background):**
This is the hidden load. Multiple ACM components use search-api as a backend service
and send queries continuously in the background — independent of any human user activity.
These are not search queries from a user at a browser; they are programmatic, automated,
and always running.

| ACM Component | What it queries search for | Frequency |
|---|---|---|
| **ACM App Lifecycle — GitOps sync** | ArgoCD Applications with AppSet label, plus their related resources, batched by cluster | **Every 30 seconds**, ceil(N_clusters / 5) queries per cycle |
| **ACM Governance** | Discovered policy list, compliance status queries across managed clusters | Periodic — fires on policy evaluation cycles |
| **ACM UI** | Cluster resource management backend — every page load, every resource view | User-driven but also background refresh for dashboards |
| **MCP Server** | Direct PostgreSQL queries for AI/LLM `find_resources` calls | On-demand but potentially frequent if AI features are active |

### ACM App Lifecycle — GitOps Sync Controller (Confirmed by Source)

Source: `stolostron/multicloud-integrations` —
`pkg/controller/gitopssyncresc/gitopssyncresc_controller.go` +
`cmd/gitopssyncresc/exec/options.go`

**Default configuration:**
```
SearchSyncInterval = 30 seconds   (--search-sync-interval flag)
SearchBatchSize    = 5 clusters   (--search-batch-size flag)
```

**What it does every 30 seconds:**
```
syncResources() fires
  └── getAllManagedClusterNames()          # K8s API call
  └── for each batch of 5 clusters:
        getArgoAppsFromSearch(batch)       # GraphQL POST to search-api
          └── query: kind=Application, apigroup=argoproj.io,
                     label=apps.open-cluster-management.io/application-set=true,
                     cluster=[up to 5 clusters]
                     + related resources   # asks for related items too
```

**Actual query rate on PostgreSQL — worked example:**

With 50 managed clusters:
```
ceil(50 / 5) = 10 search-api calls per 30-second cycle
= 20 search-api calls per minute
= 1,200 search-api calls per hour

Each call → authzMiddleware → PopulateSharedCache check → actual DB SELECT
```

With 200 managed clusters:
```
ceil(200 / 5) = 40 search-api calls per 30-second cycle
= 80 search-api calls per minute
= 4,800 search-api calls per hour
```

The `related` field in the GraphQL query is significant — it asks search-api to
return not just the matching Applications but also resources related to them
(Deployments, Pods, ReplicaSets, etc.). This translates to additional JOIN-like
operations in the DB query beyond the primary SELECT.

**The compounding risk:**
Every one of these 20-80 calls/minute goes through `authzMiddleware`, which calls
`PopulateSharedCache`. If the shared cache (5-min TTL) happens to expire during
a burst of App Lifecycle queries, the first query to arrive triggers the full
cache refresh: `getPropertyTypes` (16.7s) + `findSrchAddonDisabledClusters`.
While that 16.7s query runs, subsequent App Lifecycle queries queue behind it,
holding connection slots and delaying indexer writes.

**Why this matters for diagnosis:**
Even if you scale down all human users and the ACM UI, App Lifecycle continues
sending 20-80 search queries per minute every 30 seconds. This means:
- The DB is never truly idle during normal ACM operation
- "Zero user traffic" is not the same as "zero query load"
- pg_stat_statements will show these background queries mixed in with human queries —
  you cannot distinguish them by looking at the query text alone
- Load testing or tuning done without App Lifecycle running will give misleading results
- The indexer-recovers-when-API-pauses observation is partly explained by this:
  pausing the API eliminates not just cache refresh scans but also all the
  App Lifecycle query traffic that was flowing through it

**What each App Lifecycle query path looks like in PostgreSQL:**
```
One getArgoAppsFromSearch() call:
  1. authzMiddleware → PopulateSharedCache()
       → if cache valid: skip (cheap)
       → if cache stale: getPropertyTypes (16.7s) + findSrchAddonDisabledClusters
  2. Per-user RBAC check → SelfSubjectAccessReview + user data cache queries
  3. Primary SELECT on search.resources (kind=Application, cluster IN [...])
  4. Related resources SELECT (additional query for joined resource data)

Total: 2-4 DB queries per App Lifecycle call, potentially 16.7s more if cache expired
```

**Connection pool reality:**
- Indexer: `DB_MAX_CONNECTIONS = 10`
- search-api: `DB_MAX_CONNECTIONS = 10`
- PostgreSQL `max_connections = 30` (as configured in postgres-tuning.conf)
- App Lifecycle, Governance, UI all funnel through the same search-api connection pool
- The 10 API connections serve ALL upstream consumers simultaneously
- With 50 clusters: 20 App Lifecycle calls/min arriving in bursts every 30s means
  10 calls arrive nearly simultaneously → immediately saturates the 10-connection pool
- Under concurrent App Lifecycle burst + cache refresh expiry, the 10-connection pool
  becomes a chokepoint — indexer writes queue, latency compounds

**Known expensive queries (confirmed by EXPLAIN ANALYZE):**

| Query | Source | Cost | Nature |
|---|---|---|---|
| `getPropertyTypes` | search-api cache refresh, every 5min/pod | 16.7s | Full scan + jsonb_each — 57M intermediate rows → 124 results |
| `findSrchAddonDisabledClusters` | search-api cache refresh, every 5min/pod | unknown | Self-join on search.resources × search.resources |
| `getClusterScopedResources` | search-api cache refresh, every 5min/pod | low | GIN-indexed filter, likely OK |
| Indexer UPSERTs | search-indexer, continuous | unknown | Batch size 2500, conditional on data change |
| Edge resync (`resetEdges`) | search-indexer, per collector resync | unknown | Full edge replace per cluster |
| App Lifecycle search queries | ACM App Lifecycle, continuous background | unknown | GraphQL → parameterised JSONB selects, frequency tied to reconcile loop |
| Governance policy queries | ACM Governance, periodic | unknown | GraphQL → JSONB selects scoped to policy-relevant resource kinds |

**Important:** pg_stat_statements does not tag queries with which upstream component
sent them. App Lifecycle queries and human user queries produce identical SQL patterns.
The only way to attribute load to a specific ACM component is to correlate
pg_stat_statements timing windows with component-level metrics (e.g., App Lifecycle
reconcile rate from its own Prometheus metrics).

---

## Layer 1 — Query Load Distribution

**Script:** `./db-collect.sh` → `layer1a_top_queries_by_total_time.txt`, `layer1b_high_frequency_queries.txt`, `layer1c_write_queries.txt`, `layer1d_slowest_avg_queries.txt`

**Goal:** Rank ALL queries by actual DB time consumed. Without this you are guessing.

**Critical caveat — query attribution:**
`pg_stat_statements` groups queries by normalised SQL text. It cannot tell you
whether a given SELECT came from a human user, an App Lifecycle reconcile loop,
a Governance policy cycle, or a Kubernetes health probe. All upstream consumers
of search-api funnel through the same connection pool and produce the same SQL.

To attribute load to a specific ACM component, you need to correlate:
- `pg_stat_statements` total_exec_time for a query pattern
- with the reconcile/poll rate of the suspected component (from its own Prometheus metrics)

For example: if App Lifecycle reconciles every 30 seconds and you have 50 applications,
that is ~100 GraphQL queries/minute hitting the search-api, each translating to
1-5 DB queries. That background rate exists regardless of any human user activity.

**Practical approach to attribution — controlled elimination:**
The most reliable way to attribute DB load to a specific ACM component is to
temporarily disable or scale down one component at a time and measure the change
in pg_stat_statements total_exec_time. This is the same principle as why pausing
search-api reduced indexer pressure — controlled elimination isolates the source.

```sql
-- Reset stats to get a clean measurement window
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();

-- Let it run under normal load for 30-60 minutes, then:

-- Rank by total time consumed
SELECT
  round(total_exec_time::numeric, 2)                                        AS total_ms,
  calls,
  round(mean_exec_time::numeric, 2)                                         AS avg_ms,
  round(stddev_exec_time::numeric, 2)                                       AS stddev_ms,
  round((total_exec_time / sum(total_exec_time) OVER ())::numeric * 100, 1) AS pct_of_db,
  left(query, 120)                                                          AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 15;
```

```sql
-- High-frequency queries — cheap individually but expensive in aggregate
SELECT
  calls,
  round(mean_exec_time::numeric, 2)  AS avg_ms,
  round(total_exec_time::numeric, 2) AS total_ms,
  left(query, 120)                   AS query
FROM pg_stat_statements
WHERE calls > 100
ORDER BY calls DESC
LIMIT 15;
```

```sql
-- Writes specifically — understand indexer load
SELECT
  calls,
  round(mean_exec_time::numeric, 2)  AS avg_ms,
  round(total_exec_time::numeric, 2) AS total_ms,
  rows,
  left(query, 120)                   AS query
FROM pg_stat_statements
WHERE query ILIKE '%INSERT%'
   OR query ILIKE '%UPDATE%'
   OR query ILIKE '%DELETE%'
   OR query ILIKE '%UPSERT%'
ORDER BY total_exec_time DESC
LIMIT 10;
```

**What to look for:**
- Which query owns the largest `pct_of_db`? That is your highest-leverage target.
- Is write load (indexer) or read load (API cache refresh) the dominant consumer?
- Are there unexpected queries — from health probes, monitoring, or internal PG jobs?

---

## Layer 2 — Wait Event Analysis

**Script:** `./db-collect.sh` → `layer2a_wait_events_snapshot.txt`, `layer2b_connections_by_state.txt`, `layer2c_long_running_queries.txt` (point-in-time snapshot)
**Script:** `./db-watch.sh` → live view, refreshes every 3s, flags pool saturation and long queries in real time

**Goal:** Determine what queries are blocked on during peak load.
Run this repeatedly during a collector sync burst or API cache refresh window.

```sql
SELECT
  wait_event_type,
  wait_event,
  state,
  count(*)                      AS sessions,
  left(query, 100)              AS query
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY 1, 2, 3, 5
ORDER BY 4 DESC;
```

```sql
-- Point-in-time snapshot — captures transient contention
SELECT
  pid,
  now() - query_start           AS duration,
  wait_event_type,
  wait_event,
  state,
  left(query, 100)              AS query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC NULLS LAST;
```

**Decision table — wait events map directly to root cause:**

| wait_event_type | wait_event examples | Meaning | Category |
|---|---|---|---|
| `IO` | `DataFileRead`, `WALWrite` | Working set not in shared_buffers, hitting disk | Resource or Config |
| `Lock` | `relation`, `tuple`, `transactionid` | Writers blocking readers or vice versa | Code (transaction design) |
| `LWLock` | `BufferContent`, `WALInsert` | Internal PG contention under high concurrency | Config or Resource |
| `Client` | `ClientRead` | PG waiting for app — connection pool starvation | Config |
| None (state=`active`) | — | Pure CPU — query running flat out with no blocking | Resource or Code |
| `IPC` | `BgWorkerShutdown` | Parallel worker coordination overhead | Config |

**ACM Search specific — what to watch for:**
- Indexer UPSERT blocked on `Lock / tuple` → API long-running SELECT holds row-level locks
- API query blocked on `Lock / relation` → indexer bulk delete during resync
- Many `Client` waits → connection pool exhausted, queries queuing for a slot

---

## Layer 3 — RAM: Cache Hit Ratio

**Script:** `./db-collect.sh` → `layer3a_db_cache_hit.txt`, `layer3b_table_cache_hit.txt`

**Goal:** Conclusively determine whether more RAM would help.

```sql
SELECT
  datname,
  blks_hit                                                              AS buffer_hits,
  blks_read                                                             AS disk_reads,
  round(blks_hit * 100.0 / nullif(blks_hit + blks_read, 0), 2)        AS cache_hit_pct,
  temp_files,
  pg_size_pretty(temp_bytes)                                            AS temp_spill
FROM pg_stat_database
WHERE datname = 'search';
```

```sql
-- Per-table cache hit — find which table is causing disk reads
SELECT
  relname,
  heap_blks_hit,
  heap_blks_read,
  round(heap_blks_hit * 100.0 /
    nullif(heap_blks_hit + heap_blks_read, 0), 2)                      AS cache_hit_pct,
  idx_blks_hit,
  idx_blks_read,
  round(idx_blks_hit * 100.0 /
    nullif(idx_blks_hit + idx_blks_read, 0), 2)                        AS idx_cache_hit_pct
FROM pg_statio_user_tables
WHERE schemaname = 'search'
ORDER BY heap_blks_read DESC;
```

**Decision logic:**

```
cache_hit_pct < 99%
  → Working set doesn't fit in shared_buffers
  → More RAM / larger shared_buffers will help proportionally
  → RESOURCE PROBLEM

cache_hit_pct ≥ 99% AND queries still slow
  → Data IS in memory — RAM is not the bottleneck
  → Look at CPU (Layer 2), query design (Layer 4), or locks (Layer 2)

temp_files > 0 OR temp_spill > 0
  → Sorts/hashes spilling to disk
  → Raise work_mem
  → CONFIGURATION PROBLEM
```

**For 20GB pod:** With `shared_buffers = 5GB`, the search.resources table (7.2M rows,
avg 474 bytes/row ≈ ~3.4GB uncompressed) should fit. If cache hit is low, either
shared_buffers is too small or competing scans are evicting hot pages.

---

## Layer 4 — Per-Query Plan Analysis

**Script:** `./db-collect.sh` → `layer4a_table_health.txt`, `layer4b_index_usage.txt`, `layer4c_index_hit_rates.txt` (table health and index stats)
**Manual:** EXPLAIN ANALYZE must be run per-query — take top entries from `layer1a` and run:
```bash
kubectl exec -n open-cluster-management deployment/search-postgres -- \
  psql -d search -U searchuser -c "EXPLAIN (ANALYZE, BUFFERS) <query>;"
```

**Goal:** For each top query from Layer 1, determine if slowness is fixable by config/index
or requires a code change.

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <paste query here>;
```

**Three signals to look for in the plan:**

### Signal A — Estimated vs actual rows mismatch (Config fix)
```
Seq Scan on resources  (rows=1000 estimated)  (rows=1200000 actual)
```
Planner estimated 1k, got 1.2M. Statistics are stale. Fix: aggressive autovacuum + manual
`ANALYZE search.resources`. This causes wrong plan choices — the planner may choose a nested
loop that works for 1k rows but is catastrophic for 1.2M.

### Signal B — Seq scan where index should apply (Config fix)
```
Seq Scan on resources  (rows=7200000)
  Filter: (data ? '_hubClusterResource')
  Rows Removed by Filter: 7150000
```
GIN index exists but planner ignores it. Common cause: `random_page_cost = 4.0` (default,
assumes HDD). On SSD, set `random_page_cost = 1.1-1.5`. Planner then correctly values
index scans over seq scans.

### Signal C — Wasteful work ratio (Code change required)
```
Nested Loop  rows=57,000,000 intermediate → Sort → Unique → 124 rows output
```
No index, no config change, no amount of RAM eliminates a 460,000:1 waste ratio.
The query is fundamentally doing unnecessary work. Needs redesign.

**Decision rule:**
```
actual_rows_scanned / result_rows > 1000:1  →  strong signal for Code Change
seq scan with high filter removal rate       →  check indexes and random_page_cost
estimated ≠ actual rows by >10×             →  stale stats, Config fix
```

**Specific queries to run EXPLAIN on (ACM Search):**
```sql
-- 1. getPropertyTypes (already done: 16.7s, 57M rows → 124 results = CODE CHANGE)
EXPLAIN (ANALYZE, BUFFERS) SELECT DISTINCT key, ... FROM search.resources, jsonb_each(data);

-- 2. findSrchAddonDisabledClusters (self-join, suspected expensive)
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT "mcInfo".data->>'name' AS srchAddonDisabledCluster
FROM search.resources AS "mcInfo"
LEFT OUTER JOIN search.resources AS "srchAddon"
  ON "mcInfo".data->>'name' = "srchAddon".data->>'namespace'
 AND "srchAddon".data->>'kind' = 'ManagedClusterAddOn'
 AND "srchAddon".data->>'name' = 'search-collector'
WHERE "mcInfo".data->>'kind' = 'ManagedClusterInfo'
  AND "srchAddon".uid IS NULL
  AND "mcInfo".data->>'name' != 'local-cluster';

-- 3. Indexer UPSERT (get from pg_stat_statements, paste actual query)
-- 4. Edge resync DELETE
```

---

## Layer 5 — Table Health: Bloat and Vacuum Lag

**Script:** `./db-collect.sh` → `layer4a_table_health.txt`, `layer4b_index_usage.txt`, `layer4c_index_hit_rates.txt`

**Goal:** Rule out dead tuple bloat as a hidden multiplier on all query times.

The indexer does continuous UPSERTs. Dead tuples accumulate. Every seq scan processes
dead rows too. Bloat silently makes all queries slower over time.

```sql
-- Dead tuple accumulation per table
SELECT
  relname,
  n_live_tup,
  n_dead_tup,
  round(n_dead_tup * 100.0 / nullif(n_live_tup + n_dead_tup, 0), 1)  AS dead_pct,
  last_autovacuum,
  last_autoanalyze,
  pg_size_pretty(pg_total_relation_size('search.' || relname))         AS total_size
FROM pg_stat_user_tables
WHERE schemaname = 'search'
ORDER BY n_dead_tup DESC;
```

```sql
-- Is autovacuum keeping up? Check autovacuum worker activity
SELECT pid, query, state, wait_event, now() - query_start AS duration
FROM pg_stat_activity
WHERE query LIKE 'autovacuum%';
```

```sql
-- Table bloat estimate (compare actual size vs expected size)
SELECT
  relname,
  pg_size_pretty(pg_relation_size('search.' || relname))               AS table_size,
  pg_size_pretty(pg_total_relation_size('search.' || relname))         AS total_size,
  n_live_tup,
  pg_size_pretty(
    pg_relation_size('search.' || relname) / nullif(n_live_tup, 0)
  )                                                                     AS bytes_per_live_row
FROM pg_stat_user_tables
WHERE schemaname = 'search';
```

**Decision logic:**

```
dead_pct > 5%
  → Autovacuum not keeping up with indexer write rate
  → Tune autovacuum (scale factor, cost delay) — see postgres-tuning.conf
  → CONFIGURATION PROBLEM
  → Fix this before drawing conclusions from Layer 4 —
    bloat inflates ALL query times and makes tuning decisions misleading

dead_pct < 2% AND queries still slow
  → Bloat is not the issue
  → Look at query design (Layer 4) and resources (Layer 3)
```

---

## Layer 6 — I/O Ceiling: Storage and Checkpoint Pressure

**Script:** `./db-collect.sh` → `layer5a_checkpoint_pressure.txt`, `layer6a_pg_settings.txt`, `layer6b_table_sizes.txt`
**Manual:** pod-level IOPS requires running iostat inside the pod:
```bash
kubectl exec -n open-cluster-management deployment/search-postgres -- iostat -x 2 5
```

**Goal:** Determine if the storage tier is the bottleneck or if it's underutilised.

```sql
-- Checkpoint pressure — high checkpoints_req means WAL filling too fast
SELECT
  checkpoints_timed,
  checkpoints_req,
  round(checkpoint_write_time / 1000)   AS write_s,
  round(checkpoint_sync_time / 1000)    AS sync_s,
  buffers_checkpoint,
  buffers_clean,
  buffers_backend,                      -- high = backends forced to write dirty buffers directly (bad)
  buffers_alloc
FROM pg_stat_bgwriter;
```

```bash
# IOPS utilisation from inside the pod
kubectl exec -n open-cluster-management <pg-pod> -- iostat -x 2 5

# Key columns: %util (should be < 80%), await (IO latency ms), r/s and w/s
```

**Decision logic:**

```
checkpoints_req >> checkpoints_timed
  → WAL filling faster than checkpoint_timeout allows
  → Raise max_wal_size
  → CONFIGURATION PROBLEM

buffers_backend high (> 5% of buffers_checkpoint)
  → shared_buffers exhausted, backends writing dirty pages themselves
  → Increase shared_buffers
  → RESOURCE PROBLEM

IOPS at storage class ceiling (check cloud console or iostat %util ≈ 100%)
  → Storage is the bottleneck
  → Upgrade to higher IOPS tier (gp3→io2, or local NVMe)
  → RESOURCE PROBLEM

IOPS well below ceiling AND checkpoint pressure low AND queries still slow
  → I/O is NOT the bottleneck
  → Look at query design (Layer 4) or lock contention (Layer 2)

checkpoint_sync_time very high
  → fsync latency — storage is slow to confirm writes
  → Bad storage class (NFS, slow cloud block)
  → RESOURCE PROBLEM (storage tier change)
```

---

## The Decision Matrix

Fill this after running `./db-collect.sh`. Take top entries from `layer1a`, run EXPLAIN on
each, then fill a row per query. Each row must get a verdict before moving on.

| Query / Operation | % of DB time (layer1a) | Dominant wait event (layer2a) | Cache hit (layer3a) | Rows in/out ratio (EXPLAIN) | Dead tuples (layer4a) | Verdict |
|---|---|---|---|---|---|---|
| _(top query from layer1a)_ | ?% | ? | — | ? | — | |
| _(2nd query)_ | ?% | ? | — | ? | — | |
| _(3rd query)_ | ?% | ? | — | ? | — | |
| _(write path — indexer UPSERTs)_ | ?% | Lock/IO | — | 1:1 | accumulates? | |
| _(any resync / edge query)_ | ?% | IO | — | ? | — | |
| **Total DB** | 100% | dominant? | overall% | — | overall% | **Drives resource vs code decision** |

**Verdict guide:**

| Signal | Verdict |
|---|---|
| Rows in/out ratio > 1,000:1 | Code change — query is doing irreducible wasted work |
| Seq scan + high filter removal + index exists | Config — check `random_page_cost`, `random_page_cost` |
| Estimated rows ≠ actual rows by > 10× | Config — stale stats, run `ANALYZE` |
| Cache hit < 99% | Resource — increase `shared_buffers` |
| temp_files > 0 | Config — increase `work_mem` |
| Wait event = Lock | Code — transaction or locking design |
| Wait event = IO, cache hit ≥ 99% | Resource — IOPS ceiling |
| dead_pct > 5% | Config — tune autovacuum |

---

## Decision Tree Summary

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  START: ./enable-pg-stat-statements.sh  (once per cluster)      │
  │         ./db-reset.sh  →  wait 30-60 min  →  ./db-collect.sh   │
  └──────────────────────────────┬──────────────────────────────────┘
                                 │
              ┌──────────────────▼──────────────────┐
              │  Layer 1 — layer1a (query ranking)  │◄── Run FIRST
              │  Layer 2 — layer2a (wait events)    │◄── Run IN PARALLEL
              └──────────┬────────────────┬─────────┘    (both in db-collect.sh;
                         │                │               db-watch.sh for live view)
                         │                │
           ┌─────────────▼──┐      ┌──────▼────────────┐
           │ Layer 1 result │      │ Layer 2 result    │
           └─────────────┬──┘      └──────┬────────────┘
                         │                │
         ┌───────────────┼──────┐         │
         ▼               ▼      ▼         ▼
    Write-heavy     Read-heavy  Mixed   Wait event?
    (indexer        (API /      (both)  ────────────
     dominates)     bg scans)     │     IO    → Layer 3 cache hit
         │               │        │              < 99% → RESOURCE
         ▼               ▼        │              ≥ 99% → Layer 6 IOPS
    Layer 5          Layer 4      │                       at ceiling → RESOURCE
    (bloat?)         EXPLAIN      │                       below ceiling → CODE
         │           ANALYZE      │     Lock  → CODE (transaction design)
         │               │        │     CPU   → Layer 6 IOPS → if OK → CODE
    dead_pct        waste ratio?  │     None  → pure CPU → Layer 4 EXPLAIN
    > 5%            ──────────────┼──────────────────────────────────────────
    CONFIG          > 1000:1 → CODE (query design — no tuning fixes this)
                    10-1000:1 → check indexes/stats:
                      seq scan + index exists → CONFIG (random_page_cost)
                      estimated ≠ actual rows → CONFIG (stale stats, ANALYZE)
                      no index exists → CODE (add index) or CODE (query redesign)
                    < 10:1  → query is efficient → look at Layer 2 wait events
                         │
                         ▼
              ┌───────────────────────┐
              │ Layer 3 — cache hit   │  (rules RAM in/out immediately)
              └───────────┬───────────┘
                          │
              < 99% ──────┴────── ≥ 99%
                │                    │
            RESOURCE              not a RAM problem
            (shared_buffers)      check temp_files:
                                    > 0 → CONFIG (work_mem)
                                    = 0 → look at Layer 5 bloat
                                           or Layer 6 checkpoint pressure
                                             │
                                  ┌──────────▼───────────┐
                                  │ Layer 5 — bloat      │
                                  └──────────┬───────────┘
                                             │
                                  dead_pct > 5% → CONFIG (autovacuum)
                                  dead_pct ≤ 5% → not a bloat issue
                                                   → Layer 6 I/O pressure
                                                        │
                                             ┌──────────▼──────────┐
                                             │ Layer 6 — I/O       │
                                             └──────────┬──────────┘
                                                        │
                                             checkpoints_req high → CONFIG (max_wal_size)
                                             buffers_backend high → RESOURCE (shared_buffers)
                                             IOPS at ceiling     → RESOURCE (storage tier)
                                             all clear           → revisit Layer 4
```

---

## Concrete Execution Plan

Four scripts cover the full workflow. Run in this order:

```bash
# 0. Enable pg_stat_statements (once per cluster — safe to re-run)
./enable-pg-stat-statements.sh

# 1. Start a clean measurement window
./db-reset.sh
# → wait 30-60 minutes under normal production load

# 2. Collect all Layer 1-6 diagnostic data
./db-collect.sh
# → saves 15 files to ./db-output/<timestamp>/
# → start analysis with: cat ./db-output/<timestamp>/00_summary.txt

# 3. Separately — run during a load event to catch burst patterns
./db-watch.sh
# → live snapshot every 3s, flags pool saturation and long queries
```

**After collection — for any query that ranks in the top 5 of layer1a:**
```bash
# Run EXPLAIN ANALYZE on that specific query inside the pod
kubectl exec -n open-cluster-management deployment/search-postgres -- \
  psql -d search -U searchuser -c "EXPLAIN (ANALYZE, BUFFERS) <query here>;"
```

---

## Known Findings (as of current analysis)

| Finding | Evidence | Verdict |
|---|---|---|
| `getPropertyTypes` is a 16.7s full table scan | EXPLAIN ANALYZE: 57M rows → 124 results | **Code change** — materialized view |
| API fires DB scans every 5 min even with no users | `SHARED_CACHE_TTL=300000`, K8s probes trigger authzMiddleware | **Code change** — TTL too low, or decouple from request path |
| API pausing lets indexer recover | Operational observation | Confirms read/write contention — API scans displace indexer's buffer pages |
| 6 parallel workers already used on `getPropertyTypes` | EXPLAIN ANALYZE: Workers Launched: 6 | More parallelism won't help — already maxed |
| Sort and HashAggregate used only 65kB and 40kB | EXPLAIN ANALYZE | `work_mem` increase won't help this query |
| `SHARED_CACHE_TTL` env var available | config.go default 300000ms | **Immediate mitigation**: raise to 900000 (15min) — no code change |

---

## Quick Wins Available Right Now (No Code Change)

```bash
# 1. Raise shared cache TTL — reduces scan frequency by 3x
oc set env deployment/search-api SHARED_CACHE_TTL=900000 -n open-cluster-management

# 2. Tune PostgreSQL for 20GB pod and SSD storage
#    Apply settings from postgres-tuning.conf

# 3. Force ANALYZE to fix stale statistics
kubectl exec -n open-cluster-management <pg-pod> -- psql -d search -c "ANALYZE search.resources; ANALYZE search.edges;"
```

## Code Changes Required

| Change | Impact | Effort |
|---|---|---|
| Materialized view for `getPropertyTypes` | Eliminates 16.7s query entirely — query becomes < 1ms | Medium |
| Materialized view for `findSrchAddonDisabledClusters` | Eliminates self-join scan | Medium |
| Decouple `PopulateSharedCache` from request path | Background goroutine instead of per-request | Medium |
| Stagger cache refresh across API pods | Prevent simultaneous scans from multiple replicas | Low |
