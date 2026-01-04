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
    echo "Usage: ./bootstrap.sh [gke|homelab]"
    exit 1
fi

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Error: Target must be 'gke' or 'homelab'"
    exit 1
fi

echo "🚀 Bootstrapping Nordri for target: $TARGET"

# --- Step 0: Pre-flight Checks (Rancher Desktop Specifics) ---
if command -v rdctl &> /dev/null; then
    echo "🔍 Detected Rancher Desktop (rdctl). Checking for required VM dependencies..."
    # Check for iscsiadm (required for Longhorn)
    if ! rdctl shell which iscsiadm >/dev/null 2>&1; then
        echo "⚠️  'iscsiadm' missing in Rancher Desktop VM. Installing open-iscsi..."
        rdctl shell "sudo apk update && sudo apk add open-iscsi && sudo rc-service iscsid start"
        echo "✅ Installed open-iscsi."
    else
         echo "✅ 'iscsiadm' found in VM."
    fi
fi

# --- Step 1: Install Seed Gitea (Layer 2) ---
echo "📦 [Layer 2] Installing Seed Gitea..."
helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null 2>&1
helm repo update
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -

# We use a simple configuration for the seed instance
# Cleanup function to kill port forward on exit
cleanup() {
    if [[ -n "$PF_PID" ]]; then
        echo "🧹 Stopping Port Forward (PID: $PF_PID)..."
        kill $PF_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# We use a simple configuration for the seed instance
helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --set gitea.admin.username=$GITEA_USER \
  --set gitea.admin.password=$GITEA_PASS \
  --set persistence.enabled=false \
  --set containerSecurityContext.runAsUser=1000 \
  --set containerSecurityContext.runAsGroup=1000 \
  --set podSecurityContext.fsGroup=1000 \
  --set rootless=true

echo "⏳ Waiting for Gitea to become ready..."
TIMEOUT=300
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "❌ Timeout waiting for Gitea to start."
        exit 1
    fi

    # Check if pod is Ready
    STATUS=$(kubectl get pods -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$STATUS" == "True" ]]; then
        echo "✅ Gitea pod is Ready."
        break
    fi

    echo "   ... waiting for Gitea pod to be Ready ($ELAPSED/${TIMEOUT}s)"
    # Optional: Tail a bit of logs to show activity
    kubectl logs -n gitea -l app.kubernetes.io/name=gitea --tail=1 2>/dev/null || true
    
    sleep 5
done

echo "✅ Gitea installed and running."

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

echo "✅ Configuration Hydrated to Seed Gitea."

# --- Step 2.5: Install Gateway API (Layer 2.5) ---
echo "🚪 [Layer 2.5] Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "   Verifying Gateway API CRDs..."
kubectl wait --for=condition=established --timeout=30s crd/gatewayclasses.gateway.networking.k8s.io || { echo "❌ Failed to install Gateway API CRDs"; exit 1; }
echo "✅ Gateway API CRDs installed."

echo "✈️ [Layer 2.5] Installing Crossplane Core..."
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1
helm repo update

# We install the full Crossplane Core here to ensure CRDs (Composition, Provider, etc.) are established.
# ArgoCD will later adopt this release because we use the same release name and namespace.
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.1.3 \
  --version 2.1.3

echo "⏳ Waiting for Crossplane to become ready..."
TIMEOUT=300
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "❌ Timeout waiting for Crossplane to start."
        exit 1
    fi

    # Check if pod is Ready
    STATUS=$(kubectl get pods -n crossplane-system -l app.kubernetes.io/name=crossplane -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$STATUS" == "True" ]]; then
        echo "✅ Crossplane pod is Ready."
        break
    fi

    echo "   ... waiting for Crossplane pod to be Ready ($ELAPSED/${TIMEOUT}s)"
    kubectl logs -n crossplane-system -l app.kubernetes.io/name=crossplane --tail=1 2>/dev/null || true
    
    sleep 5
done

echo "✅ Crossplane Installed."

# --- Step 3: Install ArgoCD (Layer 3) ---
echo "🔥 [Layer 3] Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd --namespace argocd \
  --set dex.enabled=false \
  --set server.insecure=true \
  --set server.extraArgs={--insecure} \
  --set configs.cm."kustomize\.buildOptions"="--load-restrictor LoadRestrictionsNone"

echo "⏳ Waiting for ArgoCD to become ready..."
TIMEOUT=300
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "❌ Timeout waiting for ArgoCD to start."
        exit 1
    fi

    # Check if argocd-server is Ready
    STATUS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$STATUS" == "True" ]]; then
        echo "✅ ArgoCD Server is Ready."
        break
    fi

    echo "   ... waiting for ArgoCD Server ($ELAPSED/${TIMEOUT}s)"
    kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=1 2>/dev/null || true
    
    sleep 5
done

echo "✅ ArgoCD installed."

# --- Step 4: Configure ArgoCD Source ---
echo "🔗 [Layer 3] Connecting Argo to Seed Gitea..."

# Since Gitea and Argo are in the same cluster, Argo can talk to Gitea via K8s DNS
# We assume the repo is public inside the cluster for read access, or we configure creds

# Apply the Root App
echo "🌱 [Layer 4] Applying Root Application..."
kubectl apply -f root-app.yaml -n argocd

echo "🎉 Bootstrap Complete! ArgoCD is now syncing from the internal Seed Gitea."
