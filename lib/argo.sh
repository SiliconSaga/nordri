#!/usr/bin/env bash
# lib/argo.sh — read-mostly helpers over ArgoCD Applications in namespace argo.
ARGO_NS="${ARGO_NS:-argo}"
ARGO_REQUEST_TIMEOUT=30

# One line per Application, name first, so one with no sync status yet still
# shows up: name<TAB>sync<TAB>health<TAB>opphase
_argo_rows() {
    kubectl get applications -n "$ARGO_NS" --request-timeout="${1:-30}s" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.operationState.phase}{"\n"}{end}' | tr -d '\r'
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
_pred_ops_done() { awk -F'\t' '$1!="" && ($4=="Running" || $4=="Terminating") {n++} END {print n+0}'; }
argo_wait_settled() { argo_wait "${1:-900}" "settled (not Unknown)" _pred_settled; }
argo_wait_synced_healthy() { argo_wait "${1:-900}" "Synced and Healthy" _pred_synced_healthy; }
argo_wait_operations_done() { argo_wait "${1:-900}" "done syncing" _pred_ops_done; }
argo_hard_refresh_all() { kubectl annotate applications.argoproj.io -n "$ARGO_NS" --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null; }

# Drop the resources finalizer so a later prune orphans the resources instead of
# deleting them (design, Decision 4 step 1). Patches metadata.finalizers to []
# only when ArgoCD's resources finalizer is the sole one; anything else is left
# alone.
argo_remove_finalizer() {
    local app="$1" fins
    fins=$(kubectl get application -n "$ARGO_NS" "$app" -o jsonpath='{.metadata.finalizers}' 2>/dev/null | tr -d '\r')
    case "$fins" in
        ""|"[]") echo "   $app: no finalizer"; return 0 ;;
        '["resources-finalizer.argocd.argoproj.io"]'|'["resources-finalizer.argocd.argoproj.io/background"]'|'["resources-finalizer.argocd.argoproj.io/foreground"]') ;;
        *) echo "   $app: finalizers are not only the resources finalizer, left alone" >&2; return 0 ;;
    esac
    kubectl patch application -n "$ARGO_NS" "$app" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null \
        && echo "   $app: resources finalizer removed"
}
