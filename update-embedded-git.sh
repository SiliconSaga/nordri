#!/bin/bash
set -e

# Nordri Update Script
# Usage: ./update.sh [gke|homelab]
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
#   GITEA_USER  Admin username for Seed Gitea. Default: read from the
#               gitea/gitea-admin-credentials Secret if present; otherwise
#               "nordri-admin".
#   GITEA_PASS  Admin password. Default: read from the
#               gitea/gitea-admin-credentials Secret (created by
#               bootstrap.sh on fresh installs). Falls back to the
#               historical "nordri-password-change-me" with a warning if
#               neither the env var nor the Secret are available — re-run
#               bootstrap.sh on the cluster to populate the Secret.
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
TARGET=$1
# Default to the historical localhost:3000 (kubectl port-forward path).
# Override with GITEA_HOST to push directly via Gitea's ingress instead.
GITEA_HOST="${GITEA_HOST:-localhost:3000}"
GITEA_REPO_NAME="nordri"
NIDAVELLIR_GITEA_REPO="nidavellir"
MIMIR_GITEA_REPO="mimir"
HEIMDALL_GITEA_REPO="heimdall"
GITEA_CREDENTIALS_NAMESPACE="gitea"
GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
GITEA_PASS_HISTORICAL_DEFAULT="nordri-password-change-me"
NIDAVELLIR_DIR="${NIDAVELLIR_DIR:-$(dirname "$SCRIPT_DIR")/nidavellir}"
MIMIR_DIR="${MIMIR_DIR:-$(dirname "$SCRIPT_DIR")/mimir}"
HEIMDALL_DIR="${HEIMDALL_DIR:-$(dirname "$SCRIPT_DIR")/heimdall}"

# Resolve Gitea admin credentials.
#
# Priority:
#   1. Explicit GITEA_USER / GITEA_PASS env vars (always win).
#   2. Secret gitea/gitea-admin-credentials read via kubectl from the
#      currently-active context (preferred — bootstrap.sh creates this).
#   3. Historical default "nordri-admin / nordri-password-change-me" with a
#      one-line warning. Useful for clusters bootstrapped before the
#      Secret-backed credential flow landed; fixed by re-running bootstrap.sh.
if [[ -z "${GITEA_USER:-}" || -z "${GITEA_PASS:-}" ]]; then
    if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        GITEA_USER="${GITEA_USER:-$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.username}' | base64 -d)}"
        GITEA_PASS="${GITEA_PASS:-$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 -d)}"
        echo "🔑 Loaded Gitea credentials from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
    fi
fi
GITEA_USER="${GITEA_USER:-nordri-admin}"
if [[ -z "${GITEA_PASS:-}" ]]; then
    GITEA_PASS="$GITEA_PASS_HISTORICAL_DEFAULT"
    echo "⚠️  No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var — using historical default password."
    echo "   Re-run bootstrap.sh on this cluster to populate the Secret with the active credentials."
fi
# Scheme defaults to http intentionally — see GITEA_SCHEME header docs.
GITEA_SCHEME="${GITEA_SCHEME:-http}"
# Single derived base URL so we don't repeat scheme/user/pass/host in 8 places.
GITEA_BASE="${GITEA_SCHEME}://${GITEA_USER}:${GITEA_PASS}@${GITEA_HOST}"
# Unauthenticated probe URL (no creds) for liveness checks.
GITEA_PROBE_URL="${GITEA_SCHEME}://${GITEA_HOST}/api/v1/version"

# Probe the Gitea endpoint for the current $GITEA_HOST. Returns 0 if Gitea
# answers /api/v1/version with HTTP 200, non-zero otherwise. Avoids
# silently sending credentials to a wrong endpoint or an unready ingress.
probe_gitea() {
    curl -fsS --max-time 5 "$GITEA_PROBE_URL" >/dev/null 2>&1
}

# Create a Gitea repo if it doesn't already exist. Treats 201 (Created)
# and 409 (already exists) as success; anything else (DNS failure, auth
# rejection, 5xx) prints the response body and fails the script — so a
# broken Gitea endpoint surfaces immediately, not deep inside the
# subsequent `git push`.
ensure_gitea_repo() {
    local repo_name=$1
    local response_file
    local status
    response_file=$(mktemp)
    status=$(curl -sS -o "$response_file" -w "%{http_code}" \
        -X POST "$GITEA_BASE/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$repo_name\", \"private\": false}") || true
    case "$status" in
        201|409)
            rm -f "$response_file"
            return 0
            ;;
        *)
            echo "❌ Failed to create or confirm Gitea repo '$repo_name' (HTTP $status):" >&2
            cat "$response_file" >&2
            echo >&2
            rm -f "$response_file"
            return 1
            ;;
    esac
}

if [[ -z "$TARGET" ]]; then
    echo "Usage: ./update.sh [gke|homelab]"
    exit 1
fi

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Error: Target must be 'gke' or 'homelab'"
    exit 1
fi

echo "🚀 Updating Nordri Configuration for target: $TARGET"

# Cleanup function to kill port forward on exit
cleanup() {
    if [[ -n "$PF_PID" ]]; then
        echo "🧹 Stopping Port Forward (PID: $PF_PID)..."
        kill $PF_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "💧 [Layer 2] Hydrating Configuration..."

# Create a temporary directory for hydration
HYDRATE_DIR=$(mktemp -d)
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

# Push to Gitea
cd $HYDRATE_DIR
git init
git config user.email "bootstrap@nordri.local"
git config user.name "Nordri Update"
git checkout -b main
git add .
git commit -m "Update Configuration for $TARGET"
git remote add origin "$GITEA_BASE/$GITEA_USER/$GITEA_REPO_NAME.git"
# Force push to overwrite the previous state with the new desired state
git push -u origin main --force
cd -

rm -rf $HYDRATE_DIR

echo "✅ Nordri configuration updated."

# Also push Nidavellir so ArgoCD picks up any changes there too.
if [[ -d "$NIDAVELLIR_DIR" ]]; then
    echo "💧 Updating Nidavellir in Seed Gitea..."

    ensure_gitea_repo "$NIDAVELLIR_GITEA_REPO"

    NIDAVELLIR_HYDRATE=$(mktemp -d)
    cp -r "$NIDAVELLIR_DIR/." "$NIDAVELLIR_HYDRATE/"
    rm -rf "$NIDAVELLIR_HYDRATE/.git"

    cd "$NIDAVELLIR_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Update"
    git checkout -b main
    git add .
    git commit -m "Update for $TARGET"
    git remote add origin "$GITEA_BASE/$GITEA_USER/$NIDAVELLIR_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$NIDAVELLIR_HYDRATE"

    echo "✅ Nidavellir updated."
else
    echo "⚠️  Nidavellir directory not found at: $NIDAVELLIR_DIR"
    echo "   Set NIDAVELLIR_DIR env var or clone nidavellir as a sibling of this repo."
fi

if [[ -d "$MIMIR_DIR" ]]; then
    echo "💧 Updating Mimir in Seed Gitea..."

    ensure_gitea_repo "$MIMIR_GITEA_REPO"

    MIMIR_HYDRATE=$(mktemp -d)
    cp -r "$MIMIR_DIR/." "$MIMIR_HYDRATE/"
    rm -rf "$MIMIR_HYDRATE/.git"

    cd "$MIMIR_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Update"
    git checkout -b main
    git add .
    git commit -m "Update for $TARGET"
    git remote add origin "$GITEA_BASE/$GITEA_USER/$MIMIR_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$MIMIR_HYDRATE"

    echo "✅ Mimir updated."
else
    echo "⚠️  Mimir directory not found at: $MIMIR_DIR"
    echo "   Set MIMIR_DIR env var or clone mimir as a sibling of this repo."
fi

if [[ -d "$HEIMDALL_DIR" ]]; then
    echo "💧 Updating Heimdall in Seed Gitea..."

    ensure_gitea_repo "$HEIMDALL_GITEA_REPO"

    HEIMDALL_HYDRATE=$(mktemp -d)
    cp -r "$HEIMDALL_DIR/." "$HEIMDALL_HYDRATE/"
    rm -rf "$HEIMDALL_HYDRATE/.git"

    cd "$HEIMDALL_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Update"
    git checkout -b main
    git add .
    git commit -m "Update for $TARGET"
    git remote add origin "$GITEA_BASE/$GITEA_USER/$HEIMDALL_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$HEIMDALL_HYDRATE"

    echo "✅ Heimdall updated."
else
    echo "⚠️  Heimdall directory not found at: $HEIMDALL_DIR"
    echo "   Set HEIMDALL_DIR env var or clone heimdall as a sibling of this repo."
fi

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
