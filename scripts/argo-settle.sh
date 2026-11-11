#!/bin/bash
set -uo pipefail

# Read-only: wait until every ArgoCD Application reports a sync status other
# than Unknown, then print the Application table. Useful after a re-hydrate,
# when every app sourced from the seed has to re-resolve its repository.
# Usage: scripts/argo-settle.sh [timeout_seconds]   (default 900)
#
# Follows kubectl's current context (KUBE_CONTEXT, if set, must match it). Exits
# 1 on timeout, with each Application's conditions in the table.

timeout=${1:-900}
interval=20

if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    echo "❌ Timeout must be a whole number of seconds, got '$timeout'." >&2
    exit 1
fi

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
    kubectl get applications -n argo -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"$1"
}

start=$(date +%s)
while true; do
    elapsed=$(( $(date +%s) - start ))
    # One line per Application, name first, so one with no sync status yet still
    # shows up: it is as unsettled as an Unknown one. A failed query is reported
    # as a failure rather than read as "nothing Unknown".
    if rows=$(kubectl get applications -n argo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\n"}{end}' 2>&1); then
        unsettled=0
        while IFS=$'\t' read -r _name s; do
            [[ -z "$_name" ]] && continue
            s=${s%$'\r'}
            [[ -z "$s" || "$s" == "Unknown" ]] && unsettled=$((unsettled + 1))
        done <<< "$rows"
        echo "   ${elapsed}s: $unsettled unsettled"
        if [[ -n "$rows" && "$unsettled" -eq 0 ]]; then
            table ""
            exit 0
        fi
    else
        echo "   ${elapsed}s: query failed: $rows" >&2
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
        echo "❌ Timeout: Applications still unsettled after ${timeout}s." >&2
        table ",MSG:.status.conditions[*].message"
        exit 1
    fi
    sleep "$interval"
done
