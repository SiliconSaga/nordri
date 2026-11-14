#!/usr/bin/env bash
# lib/gitops.sh — the pieces of a cluster's GitOps wiring that Git never carries:
# the seed's orgs, the stable in-cluster Git address, and the two bootstrap-owned
# root Applications. Idempotent, so bootstrap.sh, migrate.sh and graduate.sh all
# call it. Realm Phase 3 design, Decisions 2 and 5.
#
# Requires lib/gitea.sh sourced first (GITEA_API_URL, GITEA_USER, GITEA_PASS).

GIT_STABLE_HOST="git.gitops.svc.cluster.local:3000"
GIT_STABLE_BASE="http://$GIT_STABLE_HOST"
GIT_SEED_SERVICE="gitea-http.gitea.svc.cluster.local"
GIT_FORGEJO_SERVICE="forgejo-http.forgejo.svc.cluster.local"
GITOPS_NAMESPACE="gitops"

# Decision 2, rule 5: the canonical org keeps the realm's bare name; every other
# class is <realm>-<class>. "realm-siliconsaga" → "siliconsaga".
gitops_canonical_org() { printf '%s' "${1#realm-}"; }
gitops_vendor_org() { printf '%s-vendor' "$(gitops_canonical_org "$1")"; }
gitops_repo_url() { printf '%s/%s/%s.git' "$GIT_STABLE_BASE" "$1" "$2"; }

# Same API on Gitea and Forgejo. Credentials go through -u, never the URL.
gitops_ensure_org() {
    local org="$1" status body
    status=$(curl -sS -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" -X GET "$GITEA_API_URL/api/v1/orgs/$org") || status=000
    case "$status" in
        200) echo "   org $org: present"; return 0 ;;
        404) ;;
        *) echo "❌ GET /orgs/$org returned HTTP $status" >&2; return 1 ;;
    esac
    body=$(jq -n --arg u "$org" '{username: $u, visibility: "public", repo_admin_change_team_access: false}')
    status=$(curl -sS -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API_URL/api/v1/orgs" \
        -H 'Content-Type: application/json' -d "$body") || status=000
    [[ "$status" == 201 ]] && { echo "   org $org: created"; return 0; }
    echo "❌ creating org $org returned HTTP $status" >&2; return 1
}

gitops_git_service_target() {
    kubectl get service git -n "$GITOPS_NAMESPACE" -o 'jsonpath={.spec.externalName}' 2>/dev/null | tr -d '\r'
}

# Create the Service pointing at the seed when it does not exist. With an
# argument, (re)point it there — graduate.sh's repoint and rollback. Never
# synced by ArgoCD, so nothing self-heals it back.
gitops_ensure_git_service() {
    local target="${1:-}" current
    current="$(gitops_git_service_target)"
    if [[ -z "$target" ]]; then
        if [[ -n "$current" ]]; then echo "   Service $GITOPS_NAMESPACE/git → $current (unchanged)"; return 0; fi
        target="$GIT_SEED_SERVICE"
    elif [[ "$current" == "$target" ]]; then
        echo "   Service $GITOPS_NAMESPACE/git already → $target"; return 0
    fi
    kubectl create namespace "$GITOPS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null || return 1
apiVersion: v1
kind: Service
metadata:
  name: git
  namespace: $GITOPS_NAMESPACE
  labels:
    app.kubernetes.io/part-of: nordri
  annotations:
    nordri.siliconsaga.org/repointed-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
  type: ExternalName
  externalName: $target
  ports:
    - name: http
      port: 3000
      targetPort: 3000
EOF
    echo "   Service $GITOPS_NAMESPACE/git → $target"
}

# The two Applications bootstrap owns. Git never updates them, so every script
# that changes what they should say re-applies them through here.
gitops_apply_root_apps() {
    local realm="$1" org dir
    org="$(gitops_canonical_org "$realm")"
    dir="$(mktemp -d)"
    sed "s|__NORDRI_REPO_URL__|$(gitops_repo_url "$org" nordri)|g" "$SCRIPT_DIR/platform/root-app.yaml" > "$dir/root-app.yaml"
    sed -e "s|__REALM_REPO__|$realm|g" -e "s|__REALM_REPO_URL__|$(gitops_repo_url "$org" "$realm")|g" \
        "$SCRIPT_DIR/platform/argocd/realm-root-app.template.yaml" > "$dir/realm-root-app.yaml"
    if grep -q '__[A-Z_]*__' "$dir/root-app.yaml" "$dir/realm-root-app.yaml"; then
        echo "❌ a placeholder survived in the root Applications" >&2; rm -rf "$dir"; return 1
    fi
    kubectl apply -n argo -f "$dir/root-app.yaml" >/dev/null || { rm -rf "$dir"; return 1; }
    kubectl apply -n argo -f "$dir/realm-root-app.yaml" >/dev/null || { rm -rf "$dir"; return 1; }
    rm -rf "$dir"
    echo "   root Applications nordri-root and $realm applied (stable address, realm path cluster)"
}
