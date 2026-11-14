#!/usr/bin/env bash
# identity.sh — the cluster's single source of per-cluster facts, written once at
# bootstrap and re-applied on graduation. Realm Phase 3 design, Decision 3.
#
#   scripts/identity.sh apply <realm> <cluster>   write ConfigMap nordri/cluster-identity,
#                                                  project it onto the in-cluster ArgoCD
#                                                  cluster Secret and the cluster-identity
#                                                  EnvironmentConfig; prints a diff first
#   scripts/identity.sh show                       the live ConfigMap as key=value
#   scripts/identity.sh diff <realm> <cluster>     resolved vs live; exit 2 when they differ
#
# Follows kubectl's current context. Refuses to apply when the live ConfigMap
# names a different cluster: identity-changing scripts never rename a cluster.
# REALM_DIR overrides where the realm checkout is (default: ../../realms/<realm>
# from this repo, as bootstrap.sh). IDENTITY_SKIP_ENVCONFIG=1 skips the
# EnvironmentConfig, for bootstrap's first call before Crossplane's CRDs exist.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/identity.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
cmd="${1:-}"; shift || true
case "$cmd" in apply|diff) [[ $# -eq 2 ]] || usage ;; show) ;; *) usage ;; esac

realm_dir_for() {
    local realm="$1"
    [[ "$realm" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "❌ realm '$realm' must be a DNS-1123 label" >&2; exit 1; }
    printf '%s' "${REALM_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$realm}"
}

resolve() { # $1 realm $2 cluster → RESOLVED (key=value lines)
    local dir; dir="$(realm_dir_for "$1")"
    [[ -d "$dir" ]] || { echo "❌ realm checkout not found at $dir (set REALM_DIR)" >&2; exit 1; }
    IDENTITY_LIVE_TAILNET="$(identity_live_value tailnetNode)" RESOLVED="$(identity_resolve "$dir" "$2")" || exit 1
}
value_of() { printf '%s\n' "$RESOLVED" | sed -n "s/^$1=//p"; }

live_lines() {
    kubectl get configmap -n "$IDENTITY_NAMESPACE" "$IDENTITY_CONFIGMAP" -o json 2>/dev/null \
        | jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"' | sort
}

show_diff() { # prints the diff, returns 0 same / 2 different
    local live; live="$(live_lines)"
    if [[ -z "$live" ]]; then echo "   (no live ConfigMap $IDENTITY_NAMESPACE/$IDENTITY_CONFIGMAP)"; printf '%s\n' "$RESOLVED" | sed 's/^/ + /'; return 2; fi
    if diff <(printf '%s\n' "$live") <(printf '%s\n' "$RESOLVED") >/dev/null; then echo "   identity unchanged"; return 0; fi
    diff <(printf '%s\n' "$live") <(printf '%s\n' "$RESOLVED") | sed -n 's/^</ - /p; s/^>/ + /p'; return 2
}

apply_configmap() {
    local cluster="$1" live
    live="$(identity_live_value cluster)"
    if [[ -n "$live" && "$live" != "$cluster" ]]; then
        echo "❌ the live identity is cluster '$live', not '$cluster'. This script never renames a cluster; re-bootstrap instead." >&2; exit 1
    fi
    kubectl create namespace "$IDENTITY_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    {
        echo "apiVersion: v1"; echo "kind: ConfigMap"
        echo "metadata:"; echo "  name: $IDENTITY_CONFIGMAP"; echo "  namespace: $IDENTITY_NAMESPACE"
        echo "  labels:"; echo "    app.kubernetes.io/part-of: nordri"
        echo "data:"
        printf '%s\n' "$RESOLVED" | while IFS='=' read -r k v; do printf '  %s: %s\n' "$k" "$(jq -nr --arg v "$v" '$v|@json')"; done
    } | kubectl apply -f - >/dev/null || exit 1
    echo "✅ ConfigMap $IDENTITY_NAMESPACE/$IDENTITY_CONFIGMAP applied"
}

apply_cluster_secret() {
    local cluster env role maturity tailnet project tailnet_flag
    cluster="$(value_of cluster)"; env="$(value_of environment)"; role="$(value_of role)"
    maturity="$(value_of maturity)"; tailnet="$(value_of tailnetNode)"; project="$(value_of gcpProject)"
    tailnet_flag=false; [[ -n "$tailnet" ]] && tailnet_flag=true
    kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null || exit 1
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argo
  labels:
    argocd.argoproj.io/secret-type: cluster
    nordri.siliconsaga.org/cluster: $cluster
    nordri.siliconsaga.org/environment: $env
    nordri.siliconsaga.org/role: $role
    nordri.siliconsaga.org/tailnet: "$tailnet_flag"
  annotations:
    nordri.siliconsaga.org/tailnet-node: "$tailnet"
    nordri.siliconsaga.org/gcp-project: "$project"
    nordri.siliconsaga.org/maturity: "$maturity"
type: Opaque
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
EOF
    echo "✅ ArgoCD cluster Secret argo/in-cluster labelled for $cluster"
}

# The EnvironmentConfig handover (design, Decision 4 step 2). While ArgoCD still
# tracks the object (label app.kubernetes.io/instance), only annotate it
# Prune=false so the Git removal leaves it in place. Once untracked, strip the
# tracking metadata and write the identity's values.
apply_envconfig() {
    local tracked
    if ! kubectl get crd environmentconfigs.apiextensions.crossplane.io >/dev/null 2>&1; then
        echo "   EnvironmentConfig CRD not installed yet — skipped (re-run apply after Crossplane is up)"; return 0
    fi
    if tracked="$(kubectl get environmentconfig "$IDENTITY_CONFIGMAP" -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)"; then
        if [[ -n "$tracked" ]]; then
            kubectl annotate environmentconfig "$IDENTITY_CONFIGMAP" argocd.argoproj.io/sync-options=Prune=false --overwrite >/dev/null || exit 1
            echo "   EnvironmentConfig is still tracked by Application '$tracked': marked Prune=false, values untouched. Re-run apply after Git stops carrying it."
            return 0
        fi
        kubectl label environmentconfig "$IDENTITY_CONFIGMAP" app.kubernetes.io/instance- >/dev/null 2>&1 || true
        kubectl annotate environmentconfig "$IDENTITY_CONFIGMAP" argocd.argoproj.io/sync-options- >/dev/null 2>&1 || true
    fi
    {
        echo "apiVersion: apiextensions.crossplane.io/v1beta1"; echo "kind: EnvironmentConfig"
        echo "metadata:"; echo "  name: $IDENTITY_CONFIGMAP"
        echo "  labels:"; echo "    app.kubernetes.io/part-of: nordri"
        echo "data:"
        printf '%s\n' "$RESOLVED" | while IFS='=' read -r k v; do [[ -n "$v" ]] && printf '  %s: %s\n' "$k" "$(jq -nr --arg v "$v" '$v|@json')"; done
    } | kubectl apply -f - >/dev/null || exit 1
    echo "✅ EnvironmentConfig $IDENTITY_CONFIGMAP written from the identity"
}

case "$cmd" in
    show) live_lines ;;
    diff) resolve "$1" "$2"; show_diff ;;
    apply)
        resolve "$1" "$2"
        echo "🪪 identity for cluster '$2' (realm $1):"; show_diff || true
        apply_configmap "$2"
        apply_cluster_secret
        [[ "${IDENTITY_SKIP_ENVCONFIG:-0}" == "1" ]] || apply_envconfig
        ;;
esac
