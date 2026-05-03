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
TARGET=$1

# Validate args before anything that touches the cluster, so wrong inputs
# fail with a usage message instead of an obscure k8s/credential error.
if [[ -z "$TARGET" ]]; then
    echo "Usage: ./update.sh [gke|homelab]"
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

# Resolve Gitea admin credentials.
#
# Password priority:  GITEA_PASS env  >  Secret  >  fail with helpful message
# Username:           Secret  >  "nordri-admin"  (not user-overridable)
#
# This script does not generate or rotate passwords — that's bootstrap.sh's
# job. If neither env var nor Secret has a value, the user needs to either
# run bootstrap.sh (with GITEA_PASS=<live> for an existing cluster) or
# pass GITEA_PASS=<value> here for one-shot use.
explicit_pass="${GITEA_PASS:-}"
secret_user=""
secret_pass=""
if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
    secret_user="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.username}' | base64 --decode)"
    secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
fi

# Username (Secret > default; not user-overridable, see bootstrap.sh).
if [[ -n "$secret_user" ]]; then
    GITEA_USER="$secret_user"
else
    GITEA_USER="nordri-admin"
fi

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
unset explicit_pass secret_user secret_pass
# Scheme defaults to http intentionally — see GITEA_SCHEME header docs.
GITEA_SCHEME="${GITEA_SCHEME:-http}"
# Build URL bases. `git remote add` requires creds embedded in the URL,
# so we percent-encode user/pass to handle special chars (@, :, /, #).
# API calls go through curl -u with the credentials-less base URL.
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
GITEA_USER_ENC="$(urlencode "$GITEA_USER")"
GITEA_PASS_ENC="$(urlencode "$GITEA_PASS")"
GITEA_API_URL="${GITEA_SCHEME}://${GITEA_HOST}"
GITEA_GIT_BASE="${GITEA_SCHEME}://${GITEA_USER_ENC}:${GITEA_PASS_ENC}@${GITEA_HOST}"
GITEA_PROBE_URL="${GITEA_API_URL}/api/v1/version"

# Probe the Gitea endpoint for the current $GITEA_HOST. Returns 0 if Gitea
# answers /api/v1/version with HTTP 200, non-zero otherwise. Avoids
# silently sending credentials to a wrong endpoint or an unready ingress.
probe_gitea() {
    curl -fsS --max-time 5 "$GITEA_PROBE_URL" >/dev/null 2>&1
}

# Create a Gitea repo if it doesn't already exist. Treats 201 (Created)
# and 409 (already exists) as success; anything else (DNS failure, auth
# rejection, 5xx) retries up to 5x with a short backoff (matches
# bootstrap.sh's create_gitea_repo — Seed Gitea can intermittently fail
# sequential creates due to an `initRepository` race), then prints the
# response body and fails the script.
ensure_gitea_repo() {
    local repo_name=$1
    local max_retries=5
    local i status response_file
    for i in $(seq 1 $max_retries); do
        response_file=$(mktemp)
        # `-u user:pass` keeps credentials out of the URL so special chars
        # in $GITEA_PASS can't corrupt URL parsing.
        status=$(curl -sS -o "$response_file" -w "%{http_code}" \
            -u "$GITEA_USER:$GITEA_PASS" \
            -X POST "$GITEA_API_URL/api/v1/user/repos" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$repo_name\", \"private\": false}") || true
        case "$status" in
            201|409)
                rm -f "$response_file"
                return 0
                ;;
        esac
        if [[ $i -lt $max_retries ]]; then
            echo "   Repo creation attempt $i/$max_retries for '$repo_name' returned HTTP $status; retrying in 5s..." >&2
            rm -f "$response_file"
            sleep 5
            continue
        fi
        echo "❌ Failed to create or confirm Gitea repo '$repo_name' after $max_retries attempts (HTTP $status):" >&2
        cat "$response_file" >&2
        echo >&2
        rm -f "$response_file"
        return 1
    done
}

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
git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$GITEA_REPO_NAME.git"
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
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$NIDAVELLIR_GITEA_REPO.git"
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
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$MIMIR_GITEA_REPO.git"
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
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$HEIMDALL_GITEA_REPO.git"
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
