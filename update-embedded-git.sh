#!/bin/bash
set -e

# Nordri Update Script
# Usage: ./update.sh [gke|homelab]
# Purpose: Re-hydrates and pushes the configuration to the internal Seed Gitea
#          without reinstalling Gitea, ArgoCD, or other components.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=$1
GITEA_USER="nordri-admin"
GITEA_PASS="nordri-password-change-me"
GITEA_REPO_NAME="nordri"
NIDAVELLIR_GITEA_REPO="nidavellir"
NIDAVELLIR_DIR="${NIDAVELLIR_DIR:-$(dirname "$SCRIPT_DIR")/nidavellir}"

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

# Ensure Gitea Port Forward is active
# We check if port 3000 is open, if not we start port-forward
if ! nc -z localhost 3000 2>/dev/null; then
    echo "   Starting Port Forward to Gitea..."
    kubectl port-forward svc/gitea-http -n gitea 3000:3000 > /dev/null 2>&1 &
    PF_PID=$!
    sleep 5 # Give it a moment
else
    echo "   Port 3000 appears open, assuming existing connection or port-forward."
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
git remote add origin "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/$GITEA_REPO_NAME.git"
# Force push to overwrite the previous state with the new desired state
git push -u origin main --force
cd -

rm -rf $HYDRATE_DIR

echo "✅ Nordri configuration updated."

# Also push Nidavellir so ArgoCD picks up any changes there too.
if [[ -d "$NIDAVELLIR_DIR" ]]; then
    echo "💧 Updating Nidavellir in Seed Gitea..."

    curl -s -X POST "http://$GITEA_USER:$GITEA_PASS@localhost:3000/api/v1/user/repos" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$NIDAVELLIR_GITEA_REPO\", \"private\": false}" > /dev/null || true

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
    git remote add origin "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/$NIDAVELLIR_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$NIDAVELLIR_HYDRATE"

    echo "✅ Nidavellir updated."
else
    echo "⚠️  Nidavellir directory not found at: $NIDAVELLIR_DIR"
    echo "   Set NIDAVELLIR_DIR env var or clone nidavellir as a sibling of this repo."
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
