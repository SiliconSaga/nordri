#!/usr/bin/env bash
# migrate.sh — move a running cluster onto generic Git (realm Phase 3 design,
# 3a-5), safe to re-run. Usage: scripts/migrate.sh <realm> <cluster>
# Follows kubectl's current context (switching it is a human act); refuses when
# the live identity (if any) names another cluster. Hydrates from the local
# checkouts like update-embedded-git.sh, so run it from the branches you mean to
# migrate to. Nothing is deleted: the three Applications that carry a resources
# finalizer have only that finalizer dropped, so the ApplicationSets can adopt
# them without a cascade.
# MIGRATE_DRY_RUN=1 skips the hydrate (everything else still runs).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/gitea.sh"; . "$SCRIPT_DIR/lib/hydrate.sh"; . "$SCRIPT_DIR/lib/identity.sh"
. "$SCRIPT_DIR/lib/gitops.sh"; . "$SCRIPT_DIR/lib/kube-context.sh"; . "$SCRIPT_DIR/lib/argo.sh"
REALM="${1:-}"; CLUSTER="${2:-}"
[[ -n "$REALM" && -n "$CLUSTER" ]] || { echo "Usage: scripts/migrate.sh <realm> <cluster>"; exit 1; }
REALM_DIR="${REALM_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$REALM}"
NIDAVELLIR_DIR="${NIDAVELLIR_DIR:-$(dirname "$SCRIPT_DIR")/nidavellir}"; MIMIR_DIR="${MIMIR_DIR:-$(dirname "$SCRIPT_DIR")/mimir}"; HEIMDALL_DIR="${HEIMDALL_DIR:-$(dirname "$SCRIPT_DIR")/heimdall}"
VENDOR_MIRRORS="${VENDOR_MIRRORS:-keycloak-k8s-resources}"; HYDRATE_AUTO_INIT=true; HYDRATE_COMMITTER="Nordri Migrate"
TARGET_SERVER=seed
TEMP_DIRS=()
# Stop the port-forward seed_access_open may have started and drop every temp
# hydration dir (their git config holds the seed credential).
cleanup() {
    [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null
    [[ ${#TEMP_DIRS[@]} -gt 0 ]] && rm -rf "${TEMP_DIRS[@]}"
    return 0
}
trap cleanup EXIT

IDENTITY="$(IDENTITY_LIVE_TAILNET="$(identity_live_value tailnetNode)" identity_resolve "$REALM_DIR" "$CLUSTER")" || exit 1
TARGET="$(printf '%s\n' "$IDENTITY" | sed -n 's/^environment=//p')"
require_kube_context "$TARGET" || exit 1
LIVE_CLUSTER="$(identity_live_value cluster)"
if [[ -n "$LIVE_CLUSTER" && "$LIVE_CLUSTER" != "$CLUSTER" ]]; then
    echo "❌ This cluster's identity says it is '$LIVE_CLUSTER' (ConfigMap nordri/cluster-identity), not '$CLUSTER'. Check kubectl's current context." >&2
    exit 1
fi
GITOPS_ORG="$(gitops_canonical_org "$REALM")"; GITOPS_VENDOR_ORG="$(gitops_vendor_org "$REALM")"

echo "1/8 ApplicationSet policy override"
override=$(kubectl get configmap -n argo argocd-cmd-params-cm -o 'jsonpath={.data.applicationsetcontroller\.enable\.policy\.override}' 2>/dev/null | tr -d '\r')
[[ "$override" == "true" ]] || { echo "❌ ArgoCD does not allow ApplicationSet policy overrides (argocd-cmd-params-cm). Sync the argocd Application from a nordri main that carries it, then re-run." >&2; exit 1; }

echo "2/8 identity (ConfigMap, cluster Secret; EnvironmentConfig marked Prune=false while tracked)"
REALM_DIR="$REALM_DIR" bash "$SCRIPT_DIR/scripts/identity.sh" apply "$REALM" "$CLUSTER" || exit 1

echo "3/8 finalizers off the three Applications that carry one"
for app in tailscale-operator vegvisir velero; do argo_remove_finalizer "$app"; done

echo "4/8 seed orgs and the git Service"
# Seed credentials and port-forward exactly as update-embedded-git.sh (lib/seed-access.sh)
. "$SCRIPT_DIR/lib/seed-access.sh"; seed_access_open || exit 1
gitops_ensure_org "$GITOPS_ORG" || exit 1; gitops_ensure_org "$GITOPS_VENDOR_ORG" || exit 1
gitops_ensure_git_service || exit 1

echo "5/8 hydrate the change into the new orgs"
if [[ "${MIGRATE_DRY_RUN:-0}" == "1" ]]; then echo "   (dry run) hydrate skipped"; else
hydrate_working_tree_repo "$SCRIPT_DIR" "$GITOPS_ORG" nordri "Migration of nordri" || exit 1
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$GITOPS_ORG" nidavellir "Migration of nidavellir" || exit 1
hydrate_working_tree_repo "$MIMIR_DIR" "$GITOPS_ORG" mimir "Migration of mimir" || exit 1
hydrate_working_tree_repo "$HEIMDALL_DIR" "$GITOPS_ORG" heimdall "Migration of heimdall" || exit 1
hydrate_vendor_mirrors "$GITOPS_VENDOR_ORG" "$VENDOR_MIRRORS" || exit 1
hydrate_working_tree_repo "$REALM_DIR" "$GITOPS_ORG" "$REALM" "Migration of $REALM" || exit 1
fi

echo "6/8 root Applications at the stable address; hard refresh; wait for operations"
gitops_apply_root_apps "$REALM" || exit 1
argo_hard_refresh_all
argo_wait_operations_done 900 || exit 1

echo "7/8 identity again: take over the EnvironmentConfig"
REALM_DIR="$REALM_DIR" bash "$SCRIPT_DIR/scripts/identity.sh" apply "$REALM" "$CLUSTER" || exit 1

echo "8/8 wait for Synced and Healthy"
argo_hard_refresh_all
argo_wait_synced_healthy 1200 || exit 1
echo "✅ $CLUSTER runs generic Git from its seed. Old nordri-admin repositories remain in the seed, unreferenced."
