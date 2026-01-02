#!/bin/bash
set -e

# Nordri Bootstrap Script
# Implements the first 4 layers of the 6 layered infra build strategy:
# 1. Assume existing Kubernetes cluster available via kubectl
# 2. Installs Gitea and hydrates configuration for the specific target environment
# 3. Installs ArgoCD
# 4. Lets Argo install other cluster fundamentals

TARGET=$1
GITEA_USER="nordri-admin"
GITEA_PASS="nordri-password-change-me"
GITEA_REPO_NAME="nordri"
INTERNAL_GITEA_URL="http://gitea-http.gitea.svc.cluster.local:3000"

if [[ -z "$TARGET" ]]; then
    echo "Usage: ./bootstrap.sh --target [gke|homelab]"
    exit 1
fi

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Error: Target must be 'gke' or 'homelab'"
    exit 1
fi

echo "🚀 Bootstrapping Nordri for target: $TARGET"

# --- Step 1: Install Seed Gitea (Layer 2) ---
echo "📦 [Layer 2] Installing Seed Gitea..."
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -

# We use a simple configuration for the seed instance
helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --set gitea.admin.username=$GITEA_USER \
  --set gitea.admin.password=$GITEA_PASS \
  --set persistence.enabled=false \
  --wait

echo "✅ Gitea installed."

# --- Step 2: Hydrate Configuration (Layer 2) ---
echo "💧 [Layer 2] Hydrating Configuration..."

# Create a temporary directory for hydration
HYDRATE_DIR=$(mktemp -d)
echo "   Working in $HYDRATE_DIR"

# Clone the empty repo from the internal Gitea (via port-forward or direct interaction)
# For bootstrapping simplicity, we'll use the API/CLI to creating the repo, then just push via a temporary Git setup
# NOTE: In a real script, we might need 'kubectl port-forward' to hit localhost:3000
# For this script we assume ability to reach it or using internal DNS if running largely inside connection context (unlikely for bootstrap)
# Let's assume we do a quick port-forward in background
kubectl port-forward svc/gitea-http -n gitea 3000:3000 > /dev/null 2>&1 &
PF_PID=$!
sleep 5 # Give it a moment

# Create the repo via API
curl -X POST "http://$GITEA_USER:$GITEA_PASS@localhost:3000/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$GITEA_REPO_NAME\", \"private\": false}" || echo "Repo might already exist"

# Prepare the content
# Copy platform shared files
cp -r platform $HYDRATE_DIR/
# Copy environment specific values as the 'default' values for this cluster
mkdir -p $HYDRATE_DIR/envs
cp envs/$TARGET/values.yaml $HYDRATE_DIR/envs/values.yaml

# Dynamic Patching: Point the App-of-Apps to the correct Kustomize Overlay
# We rely on sed to replace the generic path with the overlay path
sed -i "s|path: platform/fundamentals|path: platform/fundamentals/overlays/$TARGET|g" $HYDRATE_DIR/platform/argocd/app-of-apps.yaml

# Copy the root application
cp root-app.yaml $HYDRATE_DIR/

# Push to Gitea
cd $HYDRATE_DIR
git init
git config user.email "bootstrap@nordri.local"
git config user.name "Nordri Bootstrap"
git checkout -b main
git add .
git commit -m "Hydration for $TARGET"
git remote add origin "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/$GITEA_REPO_NAME.git"
git push -u origin main --force
cd -

# Kill port forward
kill $PF_PID

echo "✅ Configuration Hydrated to Seed Gitea."

# --- Step 3: Install ArgoCD (Layer 3) ---
echo "🔥 [Layer 3] Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd --namespace argocd --wait

echo "✅ ArgoCD installed."

# --- Step 4: Configure ArgoCD Source ---
echo "🔗 [Layer 3] Connecting Argo to Seed Gitea..."

# Since Gitea and Argo are in the same cluster, Argo can talk to Gitea via K8s DNS
# We assume the repo is public inside the cluster for read access, or we configure creds

# Apply the Root App
echo "🌱 [Layer 4] Applying Root Application..."
kubectl apply -f root-app.yaml -n argocd

echo "🎉 Bootstrap Complete! ArgoCD is now syncing from the internal Seed Gitea."
