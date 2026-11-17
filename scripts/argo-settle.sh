#!/bin/bash
set -uo pipefail

# Read-only: wait until every ArgoCD Application reports a sync status other
# than Unknown, then print the Application table. Useful after a re-hydrate,
# when every app sourced from the seed has to re-resolve its repository.
# Usage: scripts/argo-settle.sh [timeout_seconds]   (default 900)
#
# Follows kubectl's current context (KUBE_CONTEXT, if set, must match it). Exits
# 1 on timeout, with each Application's conditions in the table.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/argo.sh"

timeout=${1:-900}

if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    echo "❌ Timeout must be a whole number of seconds, got '$timeout'." >&2
    exit 1
fi
timeout=$((10#$timeout))  # a leading zero would otherwise read as octal in $(( ))

current=$(kubectl config current-context 2>/dev/null | tr -d '\r') || current=""
if [[ -z "$current" ]]; then
    echo "❌ kubectl has no current context. Pick the cluster to watch: kubectl config use-context <name>" >&2
    exit 1
fi
if [[ -n "${KUBE_CONTEXT:-}" && "$KUBE_CONTEXT" != "$current" ]]; then
    echo "❌ KUBE_CONTEXT=$KUBE_CONTEXT but kubectl's current context is '$current'." >&2
    exit 1
fi
echo "🎯 kubectl context: $current"

table() {
    kubectl get applications -n "$ARGO_NS" --request-timeout="${ARGO_REQUEST_TIMEOUT}s" -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"$1"
}

# The wait loop (bounded requests, one line per Application so one with no sync
# status yet counts as unsettled) lives in lib/argo.sh.
if argo_wait_settled "$timeout"; then
    table ""
    exit 0
fi
table ",MSG:.status.conditions[*].message"
exit 1
