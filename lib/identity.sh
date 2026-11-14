#!/usr/bin/env bash
# lib/identity.sh — resolve a cluster's identity from three layers and read the
# live one. Sourced by scripts/identity.sh, bootstrap.sh, migrate.sh,
# graduate.sh and update-embedded-git.sh. Realm Phase 3 design, Decision 3.
#
# Layers, later winning: identity/defaults-<environment>.yaml, the realm's
# clusters/<cluster>.yaml, then NORDRI_IDENTITY_<KEY> environment variables
# (the layer for values that must never be committed; none exist today).
# A cluster with no realm file is a homelab lab at bootstrap maturity.

IDENTITY_NAMESPACE="nordri"
IDENTITY_CONFIGMAP="cluster-identity"
IDENTITY_REQUIRED="cluster environment role maturity"
IDENTITY_KEYS="cluster environment role maturity sourceRef tailnetNode storageClass domain harborRole harborCentral gcpProject gcpRegion pullerSchedule"
NORDRI_LIB_DIR="${NORDRI_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Print key=value per line. Flat scalars only: a line that ends in ':' or
# starts with '-' is nesting, and nesting is refused because the readers of
# these files have jq, not yq, and a silently dropped subtree is worse than a
# refusal.
identity_read_flat() {
    local file="$1" line key value n=0
    [[ -f "$file" ]] || { echo "identity: no such file: $file" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        line="${line%$'\r'}"
        [[ -z "${line// }" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
        if [[ "$line" =~ ^[[:space:]]*-|:[[:space:]]*(#.*)?$ ]]; then
            echo "identity: $file:$n is nested, and identity files are flat key: value only" >&2; return 1
        fi
        if [[ ! "$line" =~ ^([A-Za-z][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            echo "identity: $file:$n is not 'key: value': $line" >&2; return 1
        fi
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        value="${value%%[[:space:]]#*}"              # trailing comment
        value="${value%"${value##*[![:space:]]}"}"    # trailing space
        value="${value#\"}"; value="${value%\"}"      # optional quotes
        value="${value#\'}"; value="${value%\'}"
        printf '%s=%s\n' "$key" "$value"
    done < "$file"
}

# The tailnet node a cluster registers under. prod: the cluster name, unique in
# the realm. "stamped": <cluster>-<yyyymmdd-HHMM>, kept once set so a re-apply
# never renames a live device (2026-11-13 review). Empty means no operator.
identity_tailnet_default() {
    local cluster="$1" role="$2" live="${3:-}"
    case "$role" in
        prod) printf '%s' "$cluster" ;;
        *) printf '' ;;
    esac
}
identity_tailnet_stamp() {
    local cluster="$1" live="${2:-}"
    if [[ -n "$live" && "$live" == "$cluster"-* ]]; then printf '%s' "$live"; return 0; fi
    printf '%s-%s' "$cluster" "$(date -u +%Y%m%d-%H%M)"
}

# Merge the layers for <cluster> and print sorted key=value lines. Every key in
# IDENTITY_KEYS is printed (empty when unset) so readers can rely on the shape.
# IDENTITY_LIVE_TAILNET carries the live tailnetNode for the stamp rule; the
# CLI sets it from the cluster before calling this.
identity_resolve() {
    local realm_dir="$1" cluster="$2" realm_file env_file line key value
    declare -A id=()
    [[ "$cluster" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#cluster} -le 63 ]] \
        || { echo "identity: cluster '$cluster' must be a DNS-1123 label" >&2; return 1; }
    realm_file="$realm_dir/clusters/$cluster.yaml"
    if [[ -f "$realm_file" ]]; then
        while IFS='=' read -r key value; do id["$key"]="$value"; done < <(identity_read_flat "$realm_file") || return 1
        for key in environment role maturity; do
            [[ -n "${id[$key]:-}" ]] || { echo "identity: $realm_file must set $key" >&2; return 1; }
        done
    else
        echo "identity: no clusters/$cluster.yaml in $realm_dir — lab defaults (homelab, lab, bootstrap)" >&2
        id[environment]=homelab; id[role]=lab; id[maturity]=bootstrap
    fi
    env_file="$NORDRI_LIB_DIR/../identity/defaults-${id[environment]}.yaml"
    [[ -f "$env_file" ]] || { echo "identity: unknown environment '${id[environment]}' (no $env_file)" >&2; return 1; }
    declare -A merged=()
    while IFS='=' read -r key value; do merged["$key"]="$value"; done < <(identity_read_flat "$env_file") || return 1
    for key in "${!id[@]}"; do merged["$key"]="${id[$key]}"; done
    for key in $IDENTITY_KEYS; do
        value="$(printenv "NORDRI_IDENTITY_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" 2>/dev/null || true)"
        [[ -n "$value" ]] && merged["$key"]="$value"
    done
    merged[cluster]="$cluster"
    case "${merged[role]}" in lab|test|prod) ;; *) echo "identity: role '${merged[role]}' is not lab, test or prod" >&2; return 1 ;; esac
    case "${merged[maturity]}" in bootstrap|durable|full) ;; *) echo "identity: maturity '${merged[maturity]}' is not bootstrap, durable or full" >&2; return 1 ;; esac
    if [[ "${merged[role]}" == "prod" ]]; then
        merged[sourceRef]="${merged[sourceRef]:-main}"
        case "${merged[sourceRef]}" in main|live) ;; *) echo "identity: sourceRef '${merged[sourceRef]}' is not main or live" >&2; return 1 ;; esac
    else
        merged[sourceRef]=""
    fi
    if [[ "${merged[environment]}" == "gke" ]]; then
        [[ "${merged[gcpProject]:-}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
            || { echo "identity: a gke cluster must declare gcpProject in clusters/$cluster.yaml (got '${merged[gcpProject]:-}')" >&2; return 1; }
    fi
    case "${merged[tailnetNode]:-}" in
        "") merged[tailnetNode]="$(identity_tailnet_default "$cluster" "${merged[role]}")" ;;
        stamped) merged[tailnetNode]="$(identity_tailnet_stamp "$cluster" "${IDENTITY_LIVE_TAILNET:-}")" ;;
    esac
    for key in $IDENTITY_KEYS; do printf '%s=%s\n' "$key" "${merged[$key]:-}"; done | sort
}

# The live ConfigMap's value for <key>, or nothing (no ConfigMap, no key).
identity_live_value() {
    kubectl get configmap -n "$IDENTITY_NAMESPACE" "$IDENTITY_CONFIGMAP" \
        -o "jsonpath={.data.$1}" 2>/dev/null | tr -d '\r'
}
