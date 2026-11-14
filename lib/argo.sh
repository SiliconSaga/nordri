#!/usr/bin/env bash
# lib/argo.sh — helpers over ArgoCD Applications in namespace argo: the waits
# (read-only), plus the two writes migrate.sh needs, Prune=false and the
# resources-finalizer removal.
ARGO_NS="${ARGO_NS:-argo}"
ARGO_REQUEST_TIMEOUT=30

# One line per Application, name first, so one with no sync status yet still
# shows up: name<TAB>sync<TAB>health<TAB>opphase<TAB>refresh-annotation<TAB>operation
# The last column is the requested .operation itself (compact JSON, empty when
# none is pending): it is set before operationState.phase turns Running, and
# the phase still shows the previous operation's result in that window.
_argo_rows() {
    kubectl get applications -n "$ARGO_NS" --request-timeout="${1:-30}s" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.operationState.phase}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/refresh}{"\t"}{.operation}{"\n"}{end}' | tr -d '\r'
}

# argo_wait <timeout> <label> <predicate-fn>: the predicate reads the rows on
# stdin, prints the unsettled count, and the wait returns 0 once that is 0.
# kubectl has no request timeout of its own, so every request is bounded: by
# what is left of the deadline, and by ARGO_REQUEST_TIMEOUT at most. A failed
# query is reported as a failure, never as "nothing unsettled".
argo_wait() {
    local timeout="$1" label="$2" pred="$3" start elapsed remaining bounded rows n
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start )); remaining=$(( timeout - elapsed ))
        bounded=$(( remaining > 0 && remaining < ARGO_REQUEST_TIMEOUT ? remaining : ARGO_REQUEST_TIMEOUT ))
        if rows=$(_argo_rows "$bounded" 2>/dev/null); then
            n=$("$pred" <<< "$rows")
            echo "   ${elapsed}s: $n not yet $label"
            [[ -n "$rows" && "$n" -eq 0 ]] && return 0
        else
            echo "   ${elapsed}s: query failed" >&2
        fi
        [[ "$elapsed" -ge "$timeout" ]] && { echo "❌ Timeout after ${timeout}s waiting for Applications to be $label." >&2; return 1; }
        sleep 20
    done
}
_pred_settled() { awk -F'\t' '$1!="" && ($2=="" || $2=="Unknown") {n++} END {print n+0}'; }
_pred_synced_healthy() { awk -F'\t' '$1!="" && ($2!="Synced" || $3!="Healthy") {n++} END {print n+0}'; }
_pred_ops_done() { awk -F'\t' '$1!="" && ($4=="Running" || $4=="Terminating" || $6!="") {n++} END {print n+0}'; }
argo_wait_settled() { argo_wait "${1:-900}" "settled (not Unknown)" _pred_settled; }
argo_wait_synced_healthy() { argo_wait "${1:-900}" "Synced and Healthy" _pred_synced_healthy; }
argo_wait_operations_done() { argo_wait "${1:-900}" "done syncing" _pred_ops_done; }
argo_hard_refresh_all() { kubectl annotate applications.argoproj.io -n "$ARGO_NS" --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null; }

# Block until no Application still carries the refresh annotation: ArgoCD removes
# it once the controller has processed the refresh, so this is the proof that the
# waits after argo_hard_refresh_all read post-reconcile status, not stale status.
_pred_refresh_pending() { awk -F'\t' '$1!="" && $5!="" {n++} END {print n+0}'; }
argo_wait_refresh_consumed() { argo_wait "${1:-300}" "past the refresh request" _pred_refresh_pending; }

# Annotate an Application argocd.argoproj.io/sync-options: Prune=false, so the
# parent that syncs it skips it when Git stops carrying it, instead of pruning
# it (and, if a finalizer came back, cascading). Git does not own this
# annotation, so the parent's self-heal leaves it in place. Any other sync
# option already there is kept. Returns 0 when the annotation is on (or the
# Application does not exist), 1 otherwise.
argo_hold_prune() {
    local app="$1" errf cur new
    errf=$(mktemp) || return 1
    if ! cur=$(kubectl get application -n "$ARGO_NS" "$app" -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/sync-options}' 2>"$errf"); then
        if grep -q 'NotFound' "$errf"; then
            rm -f "$errf"; echo "   $app: not found, nothing to hold"; return 0
        fi
        echo "❌ $app: could not read its sync options:" >&2; cat "$errf" >&2; rm -f "$errf"; return 1
    fi
    rm -f "$errf"
    cur="${cur//$'\r'/}"
    case ",${cur// /}," in *,Prune=false,*) echo "   $app: already Prune=false"; return 0 ;; esac
    new="Prune=false"; [[ -n "$cur" ]] && new="$cur,Prune=false"
    kubectl annotate application -n "$ARGO_NS" "$app" "argocd.argoproj.io/sync-options=$new" --overwrite >/dev/null \
        || { echo "❌ $app: annotating Prune=false failed" >&2; return 1; }
    echo "   $app: marked Prune=false"
}

# Drop ArgoCD's resources finalizer(s) so a later prune orphans the resources
# instead of deleting them (design, Decision 4 step 1). Every other finalizer is
# kept. Returns 0 only when no resources finalizer remains (or the Application
# does not exist, so there is nothing to adopt); any other outcome returns 1.
argo_remove_finalizer() {
    local app="$1" prefix="resources-finalizer.argocd.argoproj.io" errf fins n keep body
    errf=$(mktemp) || return 1
    if ! fins=$(kubectl get application -n "$ARGO_NS" "$app" -o jsonpath='{.metadata.finalizers}' 2>"$errf"); then
        if grep -q 'NotFound' "$errf"; then
            rm -f "$errf"; echo "   $app: not found, nothing to adopt"; return 0
        fi
        echo "❌ $app: could not read its finalizers:" >&2; cat "$errf" >&2; rm -f "$errf"; return 1
    fi
    rm -f "$errf"
    fins=$(printf '%s' "$fins" | tr -d '\r')
    [[ -n "$fins" ]] || fins='[]'
    n=$(printf '%s' "$fins" | jq --arg p "$prefix" '[.[] | select(startswith($p))] | length') \
        || { echo "❌ $app: unreadable finalizer list: $fins" >&2; return 1; }
    [[ "$n" -gt 0 ]] || { echo "   $app: no resources finalizer"; return 0; }
    keep=$(printf '%s' "$fins" | jq -c --arg p "$prefix" '[.[] | select(startswith($p) | not)]') || return 1
    body=$(jq -cn --argjson f "$keep" '{metadata:{finalizers:$f}}') || return 1
    kubectl patch application -n "$ARGO_NS" "$app" --type merge -p "$body" >/dev/null \
        || { echo "❌ $app: patching the finalizers failed" >&2; return 1; }
    # Two checked steps, not a pipe: without the caller's pipefail a failed get
    # would read as an empty list, a false "removed".
    if ! fins=$(kubectl get application -n "$ARGO_NS" "$app" -o jsonpath='{.metadata.finalizers}' 2>/dev/null); then
        echo "❌ $app: could not re-read its finalizers after the patch" >&2; return 1
    fi
    fins=$(printf '%s' "$fins" | tr -d '\r')
    [[ -n "$fins" ]] || fins='[]'
    n=$(printf '%s' "$fins" | jq --arg p "$prefix" '[.[] | select(startswith($p))] | length') || return 1
    [[ "$n" -eq 0 ]] || { echo "❌ $app: a resources finalizer is still present after the patch: $fins" >&2; return 1; }
    echo "   $app: resources finalizer removed"
}
