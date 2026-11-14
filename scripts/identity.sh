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
# IDENTITY_TAKEOVER_ENVCONFIG=1 (migrate.sh step 7) takes an ArgoCD-tracked
# EnvironmentConfig over, but only once ArgoCD no longer wants it.
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

# Does Application <ns>/<app> still want EnvironmentConfig <name>? It does when
# its .status.resources lists the object without requiresPruning. An absent
# Application wants nothing. Prints "yes" or "no"; returns 1 when it cannot tell.
argo_wants_envconfig() {
    local ns="$1" app="$2" json n
    json="$(kubectl get application -n "$ns" "$app" -o json --ignore-not-found)" \
        || { echo "❌ could not read Application $ns/$app to check whether it still wants EnvironmentConfig $IDENTITY_CONFIGMAP" >&2; return 1; }
    [[ -n "${json//[[:space:]]/}" ]] || { echo no; return 0; }
    n="$(printf '%s' "$json" | jq -r --arg n "$IDENTITY_CONFIGMAP" \
        '[.status.resources // [] | .[] | select(.kind == "EnvironmentConfig" and .name == $n and ((.requiresPruning // false) | not))] | length')" \
        || { echo "❌ unreadable status on Application $ns/$app" >&2; return 1; }
    n="${n//$'\r'/}"
    if [[ "$n" -gt 0 ]]; then echo yes; else echo no; fi
}

# The EnvironmentConfig handover (design, Decision 4 step 2). ArgoCD tracks a
# live object by label (app.kubernetes.io/instance) or, the 3.x default, by
# annotation (argocd.argoproj.io/tracking-id), and neither marker goes away when
# Git stops carrying the object. So:
#   - a tracked EnvironmentConfig is always marked Prune=false first, so the
#     Git removal leaves it in place whatever the tracking method;
#   - its values are written only on a take-over: IDENTITY_TAKEOVER_ENVCONFIG=1
#     (migrate.sh step 7) AND every Application its markers name no longer
#     wants it (gone from .status.resources, or requiresPruning). A take-over
#     ArgoCD has not agreed to is refused, since writing then would race a sync
#     that rewrites (or, without Prune=false, deletes) the object;
#   - a take-over strips both markers, then writes. The written object always
#     carries Prune=false too.
apply_envconfig() {
    local json label tid apps app ns wants
    if ! kubectl get crd environmentconfigs.apiextensions.crossplane.io >/dev/null 2>&1; then
        echo "   EnvironmentConfig CRD not installed yet — skipped (re-run apply after Crossplane is up)"; return 0
    fi
    json="$(kubectl get environmentconfig "$IDENTITY_CONFIGMAP" -o json --ignore-not-found)" \
        || { echo "❌ could not read EnvironmentConfig $IDENTITY_CONFIGMAP" >&2; exit 1; }
    if [[ -n "${json//[[:space:]]/}" ]]; then
        label="$(printf '%s' "$json" | jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""')" || exit 1
        tid="$(printf '%s' "$json" | jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // ""')" || exit 1
        label="${label//$'\r'/}"; tid="${tid//$'\r'/}"
        if [[ -n "$label" || -n "$tid" ]]; then
            kubectl annotate environmentconfig "$IDENTITY_CONFIGMAP" argocd.argoproj.io/sync-options=Prune=false --overwrite >/dev/null || exit 1
            if [[ "${IDENTITY_TAKEOVER_ENVCONFIG:-0}" != "1" ]]; then
                echo "   EnvironmentConfig is still tracked by ArgoCD (label '${label}', tracking-id '${tid}'): marked Prune=false, values untouched. migrate.sh takes it over once Git stops carrying it."
                return 0
            fi
            # The Application each marker names: "<app>" or "<ns>_<app>" in the
            # label, "<app>:<group>/<kind>:<ns>/<name>" in the tracking-id.
            apps="$(printf '%s\n%s\n' "$label" "${tid%%:*}" | sed '/^$/d' | sort -u)"
            while IFS= read -r app; do
                ns=argo
                if [[ "$app" == *_* ]]; then ns="${app%%_*}"; app="${app#*_}"; fi
                wants="$(argo_wants_envconfig "$ns" "$app")" || exit 1
                if [[ "$wants" == yes ]]; then
                    echo "❌ Application $ns/$app still lists EnvironmentConfig $IDENTITY_CONFIGMAP as its own (Git still carries it, or ArgoCD has not re-read Git). Not taking it over; it stays Prune=false with its current values." >&2
                    echo "   Refresh $app and check that its source no longer carries the EnvironmentConfig, then re-run." >&2
                    exit 1
                fi
            done <<< "$apps"
            if [[ -n "$label" ]]; then
                kubectl label environmentconfig "$IDENTITY_CONFIGMAP" app.kubernetes.io/instance- >/dev/null || exit 1
            fi
            if [[ -n "$tid" ]]; then
                kubectl annotate environmentconfig "$IDENTITY_CONFIGMAP" argocd.argoproj.io/tracking-id- >/dev/null || exit 1
            fi
            echo "   EnvironmentConfig released by ArgoCD: tracking markers stripped, taking it over"
        fi
    fi
    {
        echo "apiVersion: apiextensions.crossplane.io/v1beta1"; echo "kind: EnvironmentConfig"
        echo "metadata:"; echo "  name: $IDENTITY_CONFIGMAP"
        echo "  labels:"; echo "    app.kubernetes.io/part-of: nordri"
        echo "  annotations:"; echo "    argocd.argoproj.io/sync-options: Prune=false"
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
