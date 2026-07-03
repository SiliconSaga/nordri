#!/bin/bash
set -e

# Nordri Update Script
# Usage: ./update-embedded-git.sh [gke|homelab]
# Purpose: Re-hydrates and pushes the configuration to the internal Seed Gitea
#          without reinstalling Gitea, ArgoCD, or other components.
#
# Optional environment overrides:
#
#   GITEA_HOST  host:port (or just host) for the in-cluster Gitea endpoint.
#               Default: "localhost:3000" — the script will start a kubectl
#               port-forward to svc/gitea-http and push via that.
#               Set to a public URL like "gitea.cmdbee.org" to skip the
#               port-forward step and push to Gitea over its real ingress.
#               Useful when (a) the workstation's git credential manager
#               intercepts localhost:3000 (Windows GCM does this), (b) the
#               cluster's Gitea is reachable directly via DNS, or (c) you
#               want to avoid the port-forward overhead.
#               Examples:
#                 GITEA_HOST=gitea.cmdbee.org ./update-embedded-git.sh gke
#                 GITEA_HOST=gitea.localhost ./update-embedded-git.sh homelab
#
#   GITEA_PASS  Admin password. Resolution order:
#                 • Explicit env var (one-shot use, doesn't touch the Secret).
#                 • gitea/gitea-admin-credentials Secret (the normal path
#                   once bootstrap.sh has run).
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
#   NIDAVELLIR_DIR / MIMIR_DIR / HEIMDALL_DIR
#               Absolute path to each sibling component's checkout. Defaults
#               to ../<name> relative to this script.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared hydration libraries (extracted from the duplicated inline blocks).
. "$SCRIPT_DIR/lib/gitea.sh"
. "$SCRIPT_DIR/lib/hydrate.sh"
. "$SCRIPT_DIR/lib/patch-nidavellir.sh"
TARGET=$1

# Validate args before anything that touches the cluster, so wrong inputs
# fail with a usage message instead of an obscure k8s/credential error.
if [[ -z "$TARGET" ]]; then
    echo "Usage: ./update-embedded-git.sh [gke|homelab]"
    exit 1
fi
if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Error: Target must be 'gke' or 'homelab'"
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "❌ This script requires 'jq' on PATH (used to URL-encode Gitea credentials)." >&2
    echo "   Install with: 'apt install jq' / 'brew install jq' / 'choco install jq'." >&2
    exit 1
}
# Default to the historical localhost:3000 (kubectl port-forward path).
# Override with GITEA_HOST to push directly via Gitea's ingress instead.
GITEA_HOST="${GITEA_HOST:-localhost:3000}"
GITEA_REPO_NAME="nordri"
NIDAVELLIR_GITEA_REPO="nidavellir"
MIMIR_GITEA_REPO="mimir"
HEIMDALL_GITEA_REPO="heimdall"
GITEA_CREDENTIALS_NAMESPACE="gitea"
GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
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

# Resolve Gitea admin credentials.
#
# Password priority:  GITEA_PASS env  >  Secret  >  fail with helpful message
# Username:           always "nordri-admin" (matches downstream ArgoCD
#                     app repoURLs; see bootstrap.sh header).
#
# This script does not generate or rotate passwords — that's bootstrap.sh's
# job. If neither env var nor Secret has a value, the user needs to either
# run bootstrap.sh (with GITEA_PASS=<live> for an existing cluster) or
# pass GITEA_PASS=<value> here for one-shot use.
explicit_pass="${GITEA_PASS:-}"
secret_pass=""
if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
    secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
fi

# Username is fixed (see bootstrap.sh header for rationale).
GITEA_USER="nordri-admin"

# Password
if [[ -n "$explicit_pass" ]]; then
    GITEA_PASS="$explicit_pass"
elif [[ -n "$secret_pass" ]]; then
    GITEA_PASS="$secret_pass"
    echo "🔑 Loaded Gitea credentials from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
else
    echo "❌ No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
    echo "   For a cluster bootstrapped before the Secret-backed flow landed:" >&2
    echo "     • One-shot:  GITEA_PASS=<live-pw> $0 $TARGET" >&2
    echo "     • Persist:   GITEA_PASS=<live-pw> $(dirname "$0")/bootstrap.sh $TARGET" >&2
    echo "   For a fresh cluster, run bootstrap.sh first." >&2
    exit 1
fi
unset explicit_pass secret_pass
# Scheme defaults to http intentionally — see GITEA_SCHEME header docs.
GITEA_SCHEME="${GITEA_SCHEME:-http}"
# Guard: the kubectl port-forward target (svc/gitea-http) only speaks plain
# HTTP, so GITEA_SCHEME=https against localhost:3000 will fail. Force http
# and warn loudly if the caller mistakenly mixed them.
if [[ "$GITEA_HOST" == "localhost:3000" && "$GITEA_SCHEME" != "http" ]]; then
    echo "⚠️  Ignoring GITEA_SCHEME=$GITEA_SCHEME with default localhost:3000 — the port-forwarded gitea-http service is HTTP-only. Forcing http."
    GITEA_SCHEME="http"
fi
# Build URL bases. `git remote add` requires creds embedded in the URL,
# so we percent-encode user/pass to handle special chars (@, :, /, #).
# API calls go through curl -u with the credentials-less base URL.
gitea_build_urls

# gitea_ensure_repo (create-if-missing; auto_init for fresh repos) lives in lib/gitea.sh.

echo "🚀 Updating Nordri Configuration for target: $TARGET"

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

# Create a temporary directory for hydration
HYDRATE_DIR=$(mktemp -d)
TEMP_DIRS+=("$HYDRATE_DIR")
echo "   Working in $HYDRATE_DIR"

# Ensure Gitea is reachable. Either way (localhost port-forward or
# overridden public host) we probe /api/v1/version before continuing —
# `nc` only proves *something* is on the port; we want to confirm it's
# actually Gitea before sending credentials.
if [[ "$GITEA_HOST" == "localhost:3000" ]]; then
    if probe_gitea; then
        echo "   Reusing existing Gitea endpoint at $GITEA_HOST."
    else
        echo "   Starting Port Forward to Gitea..."
        kubectl port-forward svc/gitea-http -n gitea 3000:3000 > /dev/null 2>&1 &
        PF_PID=$!
        # Poll until the port-forward serves Gitea, or fail loudly.
        ATTEMPTS=0
        until probe_gitea; do
            ATTEMPTS=$((ATTEMPTS + 1))
            if [[ $ATTEMPTS -ge 30 ]]; then
                echo "❌ Gitea did not become reachable on $GITEA_HOST within 30s." >&2
                exit 1
            fi
            sleep 1
        done
    fi
else
    echo "   Using GITEA_HOST=$GITEA_HOST (skipping port-forward)."
    if ! probe_gitea; then
        echo "❌ Gitea is not answering at $GITEA_PROBE_URL." >&2
        echo "   Verify the HTTPRoute is deployed and DNS resolves." >&2
        exit 1
    fi
fi

# Prepare the content
# Copy platform shared files
cp -r "$SCRIPT_DIR/platform" "$HYDRATE_DIR/"
# Copy environment specific values as the 'default' values for this cluster
mkdir -p "$HYDRATE_DIR/envs"
cp "$SCRIPT_DIR/envs/$TARGET/values.yaml" "$HYDRATE_DIR/envs/values.yaml"

# Dynamic Patching: Point the App-of-Apps to the correct Kustomize Overlay
# We rely on sed to replace the generic path with the overlay path
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|path: platform/fundamentals|path: platform/fundamentals/overlays/$TARGET|g" $HYDRATE_DIR/platform/argocd/app-of-apps.yaml
else
    sed -i "s|path: platform/fundamentals|path: platform/fundamentals/overlays/$TARGET|g" $HYDRATE_DIR/platform/argocd/app-of-apps.yaml
fi

# Copy the root application (optional, but good for completeness)
cp "$SCRIPT_DIR/platform/root-app.yaml" "$HYDRATE_DIR/"

# Ensure the nordri repo exists in Gitea before pushing. The Seed Gitea
# runs without persistence; if the pod ever rotates and the repo got lost
# (we hit exactly this earlier — postgres survived but blob storage
# didn't), `git push` would fail with a misleading "remote rejected"
# error. ensure_gitea_repo treats 201/409 as success and retries
# transport errors.
gitea_ensure_repo "$GITEA_REPO_NAME"

# Push to Gitea
cd $HYDRATE_DIR
git init
git config user.email "bootstrap@nordri.local"
git config user.name "Nordri Update"
git checkout -b main
git add .
git commit -m "Update Configuration for $TARGET"
git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$GITEA_REPO_NAME.git"
# Force push to overwrite the previous state with the new desired state
git push -u origin main --force
cd -

rm -rf $HYDRATE_DIR

echo "✅ Nordri configuration updated."

# Also push Nidavellir so ArgoCD picks up any changes there too.
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$NIDAVELLIR_GITEA_REPO" "Update for $TARGET" patch_nidavellir_tree

hydrate_working_tree_repo "$MIMIR_DIR" "$MIMIR_GITEA_REPO" "Update for $TARGET"

hydrate_working_tree_repo "$HEIMDALL_DIR" "$HEIMDALL_GITEA_REPO" "Update for $TARGET"

# Vendor mirrors: push real history + tags so in-cluster apps can pin exact
# upstream refs. See lib/hydrate.sh for the heads-vs-tags prune rationale.
hydrate_vendor_mirrors "$VENDOR_MIRRORS"

echo "✅ Configuration Updated."
echo "🔄 Triggering ArgoCD Sync (Root App)..."
# Try to sync if argocd CLI is available, otherwise just warn
if command -v argocd &> /dev/null; then
     # We assume user is logged in or we might need to skip this
     argocd app sync root-app --local || echo "⚠️ Could not trigger sync via CLI. ArgoCD will auto-sync shortly."
else
    echo "ℹ️ ArgoCD CLI not found. ArgoCD will auto-sync within 3 minutes."
fi

echo "🎉 Update Complete!"
