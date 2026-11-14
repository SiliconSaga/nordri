#!/bin/bash
set -e

# Nordri Update Script
# Usage: ./update-embedded-git.sh <realm> [--target forgejo]
# Purpose: Re-hydrates and pushes the checkouts to the cluster's Git server
#          without reinstalling Gitea, ArgoCD, or other components. Nothing is
#          rewritten on the way in: every per-cluster value lives in the
#          cluster-identity ConfigMap (nordri/cluster-identity), which is also
#          where this script learns which cluster, environment and role it is
#          talking to. It follows kubectl's CURRENT context and never switches it.
#
#   <realm>            the owning realm (checkout at ../../realms/<realm>, or REALM_DIR)
#   --target forgejo   push to the cluster's Forgejo instead of the seed Gitea.
#                      Default: whatever the gitops/git Service points at. Refused
#                      on a graduated prod cluster, whose Forgejo is written only
#                      by its puller.
#
# Optional environment overrides:
#
#   GITEA_HOST  host:port (or just host) for the in-cluster Git endpoint.
#               Default: "localhost:3000" — the script will start a kubectl
#               port-forward to the target's HTTP Service and push via that.
#               Set to a public URL like "gitea.cmdbee.org" to skip the
#               port-forward step and push over the real ingress.
#               Useful when (a) the workstation's git credential manager
#               intercepts localhost:3000 (Windows GCM does this), (b) the
#               cluster's Gitea is reachable directly via DNS, or (c) you
#               want to avoid the port-forward overhead.
#               Examples:
#                 GITEA_HOST=gitea.cmdbee.org ./update-embedded-git.sh realm-siliconsaga
#                 GITEA_HOST=gitea.localhost ./update-embedded-git.sh realm-siliconsaga
#
#   GITEA_PASS  Admin password. Resolution order:
#                 • Explicit env var (one-shot use, doesn't touch the Secret).
#                 • The target's admin Secret (gitea/gitea-admin-credentials for
#                   the seed, forgejo/forgejo-admin for Forgejo).
#               Fails fast with a helpful message if neither is available.
#               This script does NOT generate or rotate passwords — that's
#               bootstrap.sh's job.
#   GITEA_SCHEME  http or https. Default: http. Stays on http for now
#               because the Gateway's websecure listener only carries the
#               cluster's bootstrap self-signed cert until the Vegvísir
#               wildcard-cert work lands. Set GITEA_SCHEME=https once a
#               trusted cert is wired into the listener so credentials
#               aren't sent in cleartext. (See gitea-gke.yaml header for
#               the broader writeup.)
#
#   REALM_DIR   The owning realm's checkout. Default: ../../realms/<realm>.
#
#   NIDAVELLIR_DIR / MIMIR_DIR / HEIMDALL_DIR
#               Absolute path to each sibling component's checkout. Defaults
#               to ../<name> relative to this script.
#
#   KUBE_CONTEXT  Optional. The kubectl context this run is for; the script
#               refuses to start if the current context differs (it never
#               switches contexts itself — the context is a human act). Set or
#               not, a gke environment requires a gke_* context and a homelab
#               one refuses it — see lib/kube-context.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared hydration libraries (extracted from the duplicated inline blocks).
. "$SCRIPT_DIR/lib/gitea.sh"
. "$SCRIPT_DIR/lib/hydrate.sh"
. "$SCRIPT_DIR/lib/identity.sh"
. "$SCRIPT_DIR/lib/gitops.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"

# Validate args before anything that touches the cluster, so wrong inputs
# fail with a usage message instead of an obscure k8s/credential error.
REALM="${1:-}"; TARGET_SERVER="service"
[[ -n "$REALM" ]] || { echo "Usage: ./update-embedded-git.sh <realm> [--target forgejo]"; exit 1; }
shift
while [[ $# -gt 0 ]]; do case "$1" in
    --target) TARGET_SERVER="${2:-}"; shift 2 ;;
    *) echo "❌ unknown argument '$1'" >&2; exit 1 ;;
esac; done
if [[ ! "$REALM" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || [[ ${#REALM} -gt 63 ]]; then
    echo "❌ Realm '$REALM' must be a DNS-1123 label (lowercase alphanumeric and '-', max 63 chars) — it names a Gitea repo and a Kubernetes Application." >&2
    exit 1
fi
REALM_DIR="${REALM_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$REALM}"
if [[ ! -d "$REALM_DIR/cluster" ]]; then
    echo "❌ Realm '$REALM' has no cluster/ config at: $REALM_DIR/cluster (set REALM_DIR or clone the realm)." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "❌ This script requires 'jq' on PATH (used to URL-encode Gitea credentials)." >&2
    echo "   Install with: 'apt install jq' / 'brew install jq' / 'choco install jq'." >&2
    exit 1
}

# The cluster says what it is; the script follows the current context and
# refuses one that does not fit. This is the script that once read a local
# cluster's Gitea Secret and sent it to gke.
CLUSTER="$(identity_live_value cluster)"; ROLE="$(identity_live_value role)"; TARGET="$(identity_live_value environment)"
[[ -n "$CLUSTER" && -n "$TARGET" ]] || { echo "❌ no cluster identity on this cluster (ConfigMap nordri/cluster-identity). Bootstrap or migrate it first." >&2; exit 1; }
require_kube_context "$TARGET" || exit 1
GITOPS_ORG="$(gitops_canonical_org "$REALM")"; GITOPS_VENDOR_ORG="$(gitops_vendor_org "$REALM")"
git_target="$(gitops_git_service_target)"
case "$TARGET_SERVER" in
    service)
        if [[ "$git_target" == "$GIT_FORGEJO_SERVICE" ]]; then
            if [[ "$ROLE" == "prod" ]]; then
                echo "❌ cluster $CLUSTER has graduated: its Forgejo is written only by its puller. Change GitHub instead." >&2; exit 1
            fi
            TARGET_SERVER=forgejo
        else
            TARGET_SERVER=seed
        fi ;;
    forgejo)
        [[ "$ROLE" != "prod" ]] || { echo "❌ --target forgejo is refused on a prod cluster ($CLUSTER)." >&2; exit 1; } ;;
    seed) ;;
    *) echo "❌ --target must be forgejo (or omitted)" >&2; exit 1 ;;
esac
echo "🎯 pushing to the $TARGET_SERVER on cluster $CLUSTER (git Service → ${git_target:-unset})"

# Default to the historical localhost:3000 (kubectl port-forward path).
# Override with GITEA_HOST to push directly via the server's ingress instead.
GITEA_HOST="${GITEA_HOST:-localhost:3000}"
GITEA_REPO_NAME="nordri"
NIDAVELLIR_GITEA_REPO="nidavellir"
MIMIR_GITEA_REPO="mimir"
HEIMDALL_GITEA_REPO="heimdall"
NIDAVELLIR_DIR="${NIDAVELLIR_DIR:-$(dirname "$SCRIPT_DIR")/nidavellir}"
MIMIR_DIR="${MIMIR_DIR:-$(dirname "$SCRIPT_DIR")/mimir}"
HEIMDALL_DIR="${HEIMDALL_DIR:-$(dirname "$SCRIPT_DIR")/heimdall}"

# Vendored upstream mirrors (declared in the realm ecosystem.yaml with
# tier: vendor). Unlike the working-tree repos above — which hydrate as a
# fresh orphan commit of the local tree — vendor mirrors push their REAL
# git history and tags, so in-cluster ArgoCD apps can pin exact upstream
# tags (e.g. keycloak-operator pins targetRevision "26.6.3"). Space-
# separated list of component dir names under the workspace components/.
VENDOR_MIRRORS="${VENDOR_MIRRORS:-keycloak-k8s-resources}"
# Day-2 hydration commits are authored as "Nordri Update" (bootstrap uses the default).
HYDRATE_COMMITTER="Nordri Update"
# Recreate lost seed repos with auto_init so Gitea has a resolvable HEAD (ArgoCD
# targetRevision: HEAD). No-op for existing repos (409) — it only matters on the
# rotation-recovery path this script is explicitly resilient to.
HYDRATE_AUTO_INIT=true

# Resolve the admin credentials of the server being pushed to.
#
# Password priority:  GITEA_PASS env  >  the target's Secret  >  fail with a
#                     helpful message
# Seed username:      always "nordri-admin" (matches downstream ArgoCD app
#                     repoURLs; see bootstrap.sh header). Forgejo's admin
#                     username comes from its own Secret.
#
# This script does not generate or rotate passwords — that's bootstrap.sh's
# job. If neither env var nor Secret has a value, the user needs to either
# run bootstrap.sh (with GITEA_PASS=<live> for an existing cluster) or
# pass GITEA_PASS=<value> here for one-shot use.
explicit_pass="${GITEA_PASS:-}"
if [[ "$TARGET_SERVER" == "forgejo" ]]; then
    GITEA_CREDENTIALS_NAMESPACE="forgejo"
    GITEA_CREDENTIALS_SECRET="forgejo-admin"
    GITEA_PF_SERVICE="svc/forgejo-http"
    GITEA_PF_NAMESPACE="forgejo"
else
    GITEA_CREDENTIALS_NAMESPACE="gitea"
    GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
    GITEA_PF_SERVICE="svc/gitea-http"
    GITEA_PF_NAMESPACE="gitea"
fi
secret_pass=""
if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
    secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
fi

if [[ "$TARGET_SERVER" == "forgejo" ]]; then
    GITEA_USER="$(kubectl get secret -n forgejo forgejo-admin -o jsonpath='{.data.username}' | base64 -d)"
    [[ -n "$GITEA_USER" ]] || { echo "❌ forgejo/forgejo-admin has no username." >&2; exit 1; }
else
    # Username is fixed (see bootstrap.sh header for rationale).
    GITEA_USER="nordri-admin"
fi

# Password
if [[ -n "$explicit_pass" ]]; then
    GITEA_PASS="$explicit_pass"
elif [[ -n "$secret_pass" ]]; then
    GITEA_PASS="$secret_pass"
    echo "🔑 Loaded credentials from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
else
    echo "❌ No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
    echo "   For a cluster bootstrapped before the Secret-backed flow landed:" >&2
    echo "     • One-shot:  GITEA_PASS=<live-pw> $0 $REALM" >&2
    echo "     • Persist:   GITEA_PASS=<live-pw> $(dirname "$0")/bootstrap.sh $REALM $CLUSTER" >&2
    echo "   For a fresh cluster, run bootstrap.sh first." >&2
    exit 1
fi
unset explicit_pass secret_pass
# Scheme defaults to http intentionally — see GITEA_SCHEME header docs.
GITEA_SCHEME="${GITEA_SCHEME:-http}"
# Guard: the kubectl port-forward target only speaks plain HTTP, so
# GITEA_SCHEME=https against localhost:3000 will fail. Force http and warn
# loudly if the caller mistakenly mixed them.
if [[ "$GITEA_HOST" == "localhost:3000" && "$GITEA_SCHEME" != "http" ]]; then
    echo "⚠️  Ignoring GITEA_SCHEME=$GITEA_SCHEME with default localhost:3000 — the port-forwarded service is HTTP-only. Forcing http."
    GITEA_SCHEME="http"
fi
# Build URL bases. `git remote add` requires creds embedded in the URL,
# so we percent-encode user/pass to handle special chars (@, :, /, #).
# API calls go through a curl config file, never argv.
gitea_build_urls

# gitea_ensure_repo (create-if-missing; auto_init for fresh repos) lives in lib/gitea.sh.

echo "🚀 Updating Nordri Configuration for cluster $CLUSTER (environment: $TARGET)"

# Cleanup on every script exit (success or failure) — kills the
# port-forward and removes any temp hydration dirs we registered.
# `git remote add` writes the embedded admin password into each temp
# dir's .git/config; without trap-based cleanup, `set -e` exits before
# the success-path `rm -rf` runs on a push failure, leaving credentials
# on disk.
declare -a TEMP_DIRS=()
cleanup() {
    if [[ -n "${PF_PID:-}" ]]; then
        echo "🧹 Stopping Port Forward (PID: $PF_PID)..."
        kill "$PF_PID" 2>/dev/null || true
    fi
    local d
    for d in "${TEMP_DIRS[@]}"; do
        if [[ -n "$d" && -d "$d" ]]; then
            rm -rf "$d"
        fi
    done
}
trap cleanup EXIT

echo "💧 [Layer 2] Hydrating Configuration..."

# Ensure the server is reachable. Either way (localhost port-forward or
# overridden public host) we probe /api/v1/version before continuing —
# `nc` only proves *something* is on the port; we want to confirm it's
# actually Gitea/Forgejo before sending credentials.
if [[ "$GITEA_HOST" == "localhost:3000" ]]; then
    if probe_gitea; then
        echo "   Reusing existing endpoint at $GITEA_HOST."
    else
        echo "   Starting Port Forward to $GITEA_PF_SERVICE ($GITEA_PF_NAMESPACE)..."
        kubectl port-forward "$GITEA_PF_SERVICE" -n "$GITEA_PF_NAMESPACE" 3000:3000 > /dev/null 2>&1 &
        PF_PID=$!
        # Poll until the port-forward serves the API, or fail loudly.
        ATTEMPTS=0
        until probe_gitea; do
            ATTEMPTS=$((ATTEMPTS + 1))
            if [[ $ATTEMPTS -ge 30 ]]; then
                echo "❌ The server did not become reachable on $GITEA_HOST within 30s." >&2
                exit 1
            fi
            sleep 1
        done
    fi
else
    echo "   Using GITEA_HOST=$GITEA_HOST (skipping port-forward)."
    if ! probe_gitea; then
        echo "❌ The server is not answering at $GITEA_PROBE_URL." >&2
        echo "   Verify the HTTPRoute is deployed and DNS resolves." >&2
        exit 1
    fi
fi

# The seed runs without persistence; if the pod ever rotates (or was reseeded)
# its orgs and repos are gone, and a `git push` would fail with a misleading
# "remote rejected" error. The org calls are idempotent; each hydrate call
# below recreates its repo (auto_init gives it a resolvable HEAD). Forgejo's
# orgs belong to its composition, so they are left alone there.
if [[ "$TARGET_SERVER" == "seed" ]]; then
    gitops_ensure_org "$GITOPS_ORG" || exit 1
    gitops_ensure_org "$GITOPS_VENDOR_ORG" || exit 1
fi

# The same hydration as bootstrap: every checkout verbatim, no overlay sed, no
# project stamp, no envs/ copy.
hydrate_working_tree_repo "$SCRIPT_DIR" "$GITOPS_ORG" "$GITEA_REPO_NAME" "Update of nordri"
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$GITOPS_ORG" "$NIDAVELLIR_GITEA_REPO" "Update of nidavellir"
hydrate_working_tree_repo "$MIMIR_DIR" "$GITOPS_ORG" "$MIMIR_GITEA_REPO" "Update of mimir"
hydrate_working_tree_repo "$HEIMDALL_DIR" "$GITOPS_ORG" "$HEIMDALL_GITEA_REPO" "Update of heimdall"

# Vendor mirrors: push real history + tags so in-cluster apps can pin exact
# upstream refs. See lib/hydrate.sh for the heads-vs-tags prune rationale.
hydrate_vendor_mirrors "$GITOPS_VENDOR_ORG" "$VENDOR_MIRRORS"

# The whole realm checkout, so ArgoCD re-syncs realm-owned config. (The realm
# root Application itself is applied by bootstrap.sh.)
hydrate_working_tree_repo "$REALM_DIR" "$GITOPS_ORG" "$REALM" "Update of $REALM"

echo "✅ Configuration Updated."
echo "🔄 Triggering ArgoCD refresh..."
# A hard-refresh annotation needs no argocd CLI and no login. It goes to every
# app because a refresh does NOT cascade from a parent app (`nordri-root`) to
# its children, and a run may hydrate several seed repos — refreshing only the
# root leaves a changed leaf on its cached revision until the next poll.
if kubectl get applications.argoproj.io -n argo -o name >/dev/null 2>&1; then
    if kubectl annotate applications.argoproj.io -n argo --all \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; then
        echo "✅ Hard refresh requested on every ArgoCD app."
    else
        echo "⚠️ Could not annotate ArgoCD apps. They will auto-sync within 3 minutes."
    fi
else
    echo "ℹ️ No ArgoCD apps readable in namespace 'argo'. They will auto-sync if present."
fi

echo "🎉 Update Complete!"
