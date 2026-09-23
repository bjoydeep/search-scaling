#!/bin/bash
# db-watch.sh
# Live connection pool monitor — run during a load event to catch the
# 30-second App Lifecycle burst pattern and connection pool saturation.
#
# Prints a new snapshot every INTERVAL seconds.
# Press Ctrl+C to stop.
#
# Usage: ./db-watch.sh [namespace] [interval_seconds]
# Defaults: namespace=open-cluster-management, interval=3

set -euo pipefail

NS=${1:-open-cluster-management}
INTERVAL=${2:-3}
POD=$(kubectl get pod -n "$NS" -l name=search-postgres --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD" ]]; then
  echo "ERROR: No running search-postgres pod found in namespace $NS"
  exit 1
fi

echo "============================================"
echo "  ACM Search DB — Live Connection Monitor"
echo "============================================"
echo "Pod:      $POD"
echo "Interval: ${INTERVAL}s   (Ctrl+C to stop)"
echo ""
echo "What to watch for:"
echo "  active=10, idle=0       → pool fully saturated"
echo "  longest_s > 15          → getPropertyTypes or resync holding a slot"
echo "  spike every ~30s        → App Lifecycle burst pattern"
echo "  idle_txn > 0            → connection leak"
echo "============================================"
echo ""
printf "%-10s | %-6s | %-6s | %-9s | %-12s | %-5s | %s\n" \
  "time" "active" "idle" "idle_txn" "longest_s" "total" "longest_query"
printf '%0.s─' {1..100}; echo

while true; do
  kubectl exec -n "$NS" "$POD" -- psql -d search -U searchuser -t -A -F'|' -c "
    SELECT
      to_char(now(), 'HH24:MI:SS'),
      count(*) FILTER (WHERE state = 'active'),
      count(*) FILTER (WHERE state = 'idle'),
      count(*) FILTER (WHERE state = 'idle in transaction'),
      coalesce(round(max(extract(epoch FROM (now() - query_start)))
        FILTER (WHERE state = 'active'))::numeric, 0),
      count(*),
      left(coalesce(
        (SELECT query FROM pg_stat_activity
         WHERE state = 'active' AND datname = 'search'
           AND query_start = (SELECT min(query_start) FROM pg_stat_activity
                              WHERE state = 'active' AND datname = 'search')
         LIMIT 1), '—'), 60)
    FROM pg_stat_activity
    WHERE datname = 'search';
  " 2>/dev/null | while IFS='|' read -r ts active idle idle_txn longest total query; do
    # Flag saturation
    flag=""
    [[ "$active" -ge 8 ]] 2>/dev/null && flag=" ◀ POOL PRESSURE"
    [[ "$active" -ge 10 ]] 2>/dev/null && flag=" ◀◀ POOL SATURATED"
    [[ "${longest:-0}" -ge 10 ]] 2>/dev/null && flag="$flag ⚠ LONG QUERY"
    printf "%-10s | %-6s | %-6s | %-9s | %-12s | %-5s | %-60s%s\n" \
      "$ts" "$active" "$idle" "$idle_txn" "${longest}s" "$total" "$query" "$flag"
  done

  sleep "$INTERVAL"
done
