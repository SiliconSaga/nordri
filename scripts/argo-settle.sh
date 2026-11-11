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

# kubectl has no request timeout of its own, so a server that accepts the
# connection and never answers would hold the loop past the deadline. Every
# request is bounded: by what is left of the deadline, and by 30s at most.
request_timeout=30
table() {
    kubectl get applications -n argo --request-timeout="${request_timeout}s" -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"$1"
}

query_err=$(mktemp)
trap 'rm -f "$query_err"' EXIT

start=$(date +%s)
while true; do
    elapsed=$(( $(date +%s) - start ))
    # One line per Application, name first, so one with no sync status yet still
    # shows up: it is as unsettled as an Unknown one. stderr goes to a file so a
    # kubectl warning cannot be read as a row, and a failed query is reported as
    # a failure rather than as "nothing Unknown".
    remaining=$(( timeout - elapsed ))
    bounded=$(( remaining > 0 && remaining < request_timeout ? remaining : request_timeout ))
    if rows=$(kubectl get applications -n argo --request-timeout="${bounded}s" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\n"}{end}' 2>"$query_err"); then
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
        echo "   ${elapsed}s: query failed: $(tr -d '\r' < "$query_err" | tail -n 1)" >&2
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
        echo "❌ Timeout: Applications still unsettled after ${timeout}s." >&2
        table ",MSG:.status.conditions[*].message"
        exit 1
    fi
    sleep "$interval"
done
