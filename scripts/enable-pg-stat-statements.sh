#!/bin/bash
# enable-pg-stat-statements.sh
#
# Enables pg_stat_statements on the ACM Search PostgreSQL pod.
# Safe to run multiple times — checks current state before each step.
#
# What this script does:
#   1. Checks if already enabled — exits early if so
#   2. Pauses the search-v2-operator to prevent configmap reconciliation
#   3. Patches custom-postgresql.conf to add shared_preload_libraries
#   4. Restarts the postgres pod (required for shared_preload_libraries)
#   5. Creates the extension in the database
#   6. Makes it permanent by adding CREATE EXTENSION to postgresql-start.sh
#   7. Restores the operator
#   8. Verifies the operator did not overwrite the config
#
# Usage: ./enable-pg-stat-statements.sh [namespace]
# Default namespace: open-cluster-management
#
# Confirmed working on ACM 2.16.x (tested 2026-09-18):
#   - custom-postgresql.conf survives operator reconciliation
#   - Operator does NOT overwrite this key on reconcile

set -euo pipefail

NS=${1:-open-cluster-management}
OPERATOR_DEPLOYMENT="search-v2-operator-controller-manager"
PG_DEPLOYMENT="search-postgres"
PG_USER="searchuser"
PG_DB="search"

# ─────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date -u '+%H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date -u '+%H:%M:%S')] ⚠ $*"; }
fail() { echo "[$(date -u '+%H:%M:%S')] ✗ $*"; exit 1; }

get_pod() {
  kubectl get pod -n "$NS" -l name=search-postgres \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

psql_cmd() {
  local pod
  pod=$(get_pod)
  kubectl exec -n "$NS" "$pod" -- \
    psql -d "$PG_DB" -U "$PG_USER" -t -A -c "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Enable pg_stat_statements — ACM Search Postgres   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "  Namespace: $NS"
echo "  Time:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────
log "Checking prerequisites..."

POD=$(get_pod)
[[ -z "$POD" ]] && fail "No running search-postgres pod found in namespace $NS"
ok "Postgres pod: $POD"

kubectl get deployment "$OPERATOR_DEPLOYMENT" -n "$NS" &>/dev/null \
  || fail "Operator deployment $OPERATOR_DEPLOYMENT not found in namespace $NS"
ok "Operator deployment found"

# ─────────────────────────────────────────────────────────────────
# Step 0 — Check if already enabled
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 0 — Checking if pg_stat_statements is already active..."

if psql_cmd "SELECT count(*) FROM pg_stat_statements;" &>/dev/null; then
  ok "pg_stat_statements is already enabled and collecting data."
  echo ""
  CURRENT_COUNT=$(psql_cmd "SELECT count(*) FROM pg_stat_statements;")
  echo "  Current statement count: $CURRENT_COUNT"
  echo ""
  echo "  Nothing to do. Run db-collect.sh to gather diagnostic data."
  exit 0
fi

warn "pg_stat_statements not active — proceeding with enablement."

# ─────────────────────────────────────────────────────────────────
# Step 1 — Pause the operator
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 1 — Pausing operator (prevents configmap reconciliation during change)..."

OPERATOR_REPLICAS=$(kubectl get deployment "$OPERATOR_DEPLOYMENT" -n "$NS" \
  -o jsonpath='{.spec.replicas}')

kubectl scale deployment "$OPERATOR_DEPLOYMENT" -n "$NS" --replicas=0
kubectl rollout status deployment "$OPERATOR_DEPLOYMENT" -n "$NS" --timeout=60s \
  2>/dev/null || true

ok "Operator scaled down (was $OPERATOR_REPLICAS replica(s))"

# ─────────────────────────────────────────────────────────────────
# Step 2 — Patch custom-postgresql.conf
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 2 — Patching custom-postgresql.conf in configmap search-postgres..."

CURRENT_CONF=$(kubectl get configmap search-postgres -n "$NS" \
  -o jsonpath='{.data.custom-postgresql\.conf}')

if echo "$CURRENT_CONF" | grep -q "pg_stat_statements"; then
  ok "shared_preload_libraries already in custom-postgresql.conf — skipping patch."
else
  kubectl patch configmap search-postgres -n "$NS" --type merge -p "$(cat <<EOF
{
  "data": {
    "custom-postgresql.conf": "shared_preload_libraries = 'pg_stat_statements'\npg_stat_statements.max = 1000\npg_stat_statements.track = all\n"
  }
}
EOF
)"
  ok "custom-postgresql.conf patched."
fi

# ─────────────────────────────────────────────────────────────────
# Step 3 — Restart postgres
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 3 — Restarting postgres (required for shared_preload_libraries)..."
warn "Note: postgres uses emptyDir storage — data will repopulate from collectors after restart."
echo ""

kubectl rollout restart deployment/"$PG_DEPLOYMENT" -n "$NS"
log "Waiting for postgres to be ready..."
kubectl rollout status deployment/"$PG_DEPLOYMENT" -n "$NS" --timeout=300s

POD=$(get_pod)
ok "Postgres ready — new pod: $POD"

# ─────────────────────────────────────────────────────────────────
# Step 4 — Create the extension
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 4 — Creating pg_stat_statements extension..."

# Wait a moment for postgres startup scripts to complete
sleep 5

psql_cmd "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
ok "Extension created."

# Verify it works
if psql_cmd "SELECT count(*) FROM pg_stat_statements;" &>/dev/null; then
  ok "pg_stat_statements is collecting — verification passed."
else
  fail "Extension created but SELECT from pg_stat_statements failed. Check postgres logs."
fi

PRELOAD=$(psql_cmd "SHOW shared_preload_libraries;" 2>/dev/null || echo "unknown")
ok "shared_preload_libraries = $PRELOAD"

# ─────────────────────────────────────────────────────────────────
# Step 5 — Make it permanent via postgresql-start.sh
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 5 — Making CREATE EXTENSION permanent in postgresql-start.sh..."

CURRENT_START=$(kubectl get configmap search-postgres -n "$NS" \
  -o jsonpath='{.data.postgresql-start\.sh}')

if echo "$CURRENT_START" | grep -q "pg_stat_statements"; then
  ok "postgresql-start.sh already contains pg_stat_statements — skipping."
else
  NEW_START="${CURRENT_START}
psql -d $PG_DB -U $PG_USER -c \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\""

  # Use a temp file to avoid quoting issues with the JSON patch
  TMPFILE=$(mktemp)
  python3 -c "
import json, sys
data = json.load(sys.stdin)
data['data']['postgresql-start.sh'] = sys.argv[1]
print(json.dumps(data))
" "$NEW_START" <<< "$(kubectl get configmap search-postgres -n "$NS" -o json)" \
  | kubectl apply -f - -n "$NS" &>/dev/null \
  || warn "Could not auto-patch postgresql-start.sh — add manually (see below)."
  rm -f "$TMPFILE"

  # Verify
  VERIFY=$(kubectl get configmap search-postgres -n "$NS" \
    -o jsonpath='{.data.postgresql-start\.sh}')
  if echo "$VERIFY" | grep -q "pg_stat_statements"; then
    ok "postgresql-start.sh updated — CREATE EXTENSION will run on every pod restart."
  else
    warn "postgresql-start.sh could not be patched automatically."
    echo ""
    echo "  ┌─ Manual step required ─────────────────────────────────────────┐"
    echo "  │ Add this line to the postgresql-start.sh key in the configmap: │"
    echo "  │                                                                 │"
    echo "  │  psql -d search -U searchuser -c \\                             │"
    echo "  │    \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\"        │"
    echo "  │                                                                 │"
    echo "  │  kubectl edit configmap search-postgres -n $NS          │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
  fi
fi

# ─────────────────────────────────────────────────────────────────
# Step 6 — Restore the operator
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 6 — Restoring operator to $OPERATOR_REPLICAS replica(s)..."

kubectl scale deployment "$OPERATOR_DEPLOYMENT" -n "$NS" --replicas="$OPERATOR_REPLICAS"
kubectl rollout status deployment "$OPERATOR_DEPLOYMENT" -n "$NS" --timeout=60s
ok "Operator restored."

# ─────────────────────────────────────────────────────────────────
# Step 7 — Verify operator did not overwrite config
# ─────────────────────────────────────────────────────────────────
echo ""
log "Step 7 — Verifying operator did not overwrite custom-postgresql.conf..."
sleep 5  # Give operator a moment to reconcile if it's going to

FINAL_CONF=$(kubectl get configmap search-postgres -n "$NS" \
  -o jsonpath='{.data.custom-postgresql\.conf}')

if echo "$FINAL_CONF" | grep -q "pg_stat_statements"; then
  ok "custom-postgresql.conf intact after operator reconciliation."
else
  warn "custom-postgresql.conf was overwritten by the operator!"
  echo "  This is unexpected — the operator should leave this key untouched."
  echo "  Re-run this script, or investigate the operator reconciliation logic."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    All done!                        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  pg_stat_statements is now active and collecting."
echo ""
echo "  Next steps:"
echo "  1. Wait 30-60 min for data to accumulate under normal load"
echo "     (collectors will repopulate data during this time too)"
echo "  2. Run: ./db-reset.sh     ← optional clean window"
echo "  3. Run: ./db-collect.sh   ← gather diagnostic snapshot"
echo ""
STMT_COUNT=$(psql_cmd "SELECT count(*) FROM pg_stat_statements;" 2>/dev/null || echo "unknown")
echo "  Current pg_stat_statements count: $STMT_COUNT"
echo "  Pod: $(get_pod)"
echo "  Time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
