#!/bin/bash
# db-reset.sh
# Resets pg_stat_statements and pg_stat counters to start a clean measurement window.
# Run this FIRST, then wait 30-60 minutes under normal load, then run db-collect.sh.
#
# Usage: ./db-reset.sh [namespace]
# Default namespace: open-cluster-management

set -euo pipefail

NS=${1:-open-cluster-management}
POD=$(kubectl get pod -n "$NS" -l name=search-postgres --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD" ]]; then
  echo "ERROR: No running search-postgres pod found in namespace $NS"
  exit 1
fi

echo "============================================"
echo "  ACM Search DB — Reset Measurement Window"
echo "============================================"
echo "Pod:       $POD"
echo "Namespace: $NS"
echo "Time:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

run() {
  kubectl exec -n "$NS" "$POD" -- psql -d search -U searchuser -c "$1"
}

echo ">>> Checking pg_stat_statements is enabled..."
if ! run "SELECT count(*) FROM pg_stat_statements;" &>/dev/null; then
  echo ""
  echo "ERROR: pg_stat_statements is not enabled."
  echo "Follow Step 0 in analytical-approach.md to enable it first."
  exit 1
fi
echo "    OK — pg_stat_statements is active."
echo ""

echo ">>> Resetting pg_stat_statements (query-level stats)..."
run "SELECT pg_stat_statements_reset();"

echo ">>> Resetting pg_stat counters (table/index/bgwriter stats)..."
run "SELECT pg_stat_reset();"

echo ""
echo "============================================"
echo "  Reset complete."
echo "  Start time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "  Next steps:"
echo "  1. Wait 30-60 minutes under normal production load."
echo "     This captures:"
echo "     - App Lifecycle GitOps sync (every 30s)"
echo "     - search-api cache refresh  (every 5min/pod)"
echo "     - Indexer collector syncs   (continuous)"
echo "     - Governance/UI queries     (background)"
echo ""
echo "  2. Run: ./db-collect.sh"
echo "============================================"
