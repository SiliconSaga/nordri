#!/bin/bash
set -e

# Nordri Bootstrap Script
# Implements a layered infra build strategy:
# 1.   Assume existing Kubernetes cluster available via kubectl
# 2.   Install Seed Gitea + hydrate configuration for the target environment
# 2.5  Install Gateway API CRDs + Crossplane Core
# 2.6  Install Traefik (registers IngressRoute CRDs needed by ArgoCD)
# 2.7  Install Crossplane Providers + Functions, wait Healthy
# 2.8  Install Crossplane ProviderConfigs + RBAC
# 3.   Install ArgoCD
# 4.   Apply Root Application (ArgoCD adopts all pre-installed components)
# 5.   Initialize Garage S3 + Velero credentials (waits for ArgoCD to deploy Garage)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
cp -r "$SCRIPT_DIR/platform" "$HYDRATE_DIR/"
# Copy environment specific values as the 'default' values for this cluster
mkdir -p "$HYDRATE_DIR/envs"
cp "$SCRIPT_DIR/envs/$TARGET/values.yaml" "$HYDRATE_DIR/envs/values.yaml"

# Dynamic Patching: Point the App-of-Apps to the correct Kustomize Overlay
# Use portable sed -i (macOS requires '' as backup extension, GNU sed does not)
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s|path: platform/fundamentals|path: platform/fundamentals/overlays/$TARGET|g" "$HYDRATE_DIR/platform/argocd/app-of-apps.yaml"
else
  sed -i "s|path: platform/fundamentals|path: platform/fundamentals/overlays/$TARGET|g" "$HYDRATE_DIR/platform/argocd/app-of-apps.yaml"
fi

# Copy the root application
cp "$SCRIPT_DIR/platform/root-app.yaml" "$HYDRATE_DIR/"

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
  --namespace crossplane --create-namespace \
  --version 2.1.4

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
    STATUS=$(kubectl get pods -n crossplane -l app.kubernetes.io/name=crossplane -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$STATUS" == "True" ]]; then
        echo "✅ Crossplane pod is Ready."
        break
    fi

    echo "   ... waiting for Crossplane pod to be Ready ($ELAPSED/${TIMEOUT}s)"
    kubectl logs -n crossplane -l app.kubernetes.io/name=crossplane --tail=1 2>/dev/null || true
    
    sleep 5
done

echo "✅ Crossplane Installed."

# --- Step 2.6: Install Traefik (Layer 2.6) ---
# Pre-install Traefik so its CRDs (IngressRoute, Middleware, etc.) exist before ArgoCD tries
# to sync IngressRoute resources. ArgoCD will adopt this Helm release on first sync.
echo "🚦 [Layer 2.6] Installing Traefik..."
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1

helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --version 38.0.1 \
  --set providers.kubernetesGateway.enabled=true \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443

echo "⏳ Waiting for Traefik to become ready..."
kubectl rollout status deployment/traefik -n kube-system --timeout=120s || { echo "❌ Traefik failed to start."; exit 1; }
echo "✅ Traefik Installed (IngressRoute CRDs now available)."

# --- Step 2.7: Install Crossplane Providers + Functions (Layer 2.7) ---
# Pre-install providers so their CRDs (ProviderConfig, etc.) exist before ArgoCD tries to sync.
echo "📦 [Layer 2.7] Installing Crossplane Providers & Functions..."
kubectl apply -f "$SCRIPT_DIR/platform/fundamentals/manifests/crossplane-providers.yaml"

echo "⏳ Waiting for Crossplane Providers to become healthy..."
kubectl wait --for=condition=Healthy providers.pkg.crossplane.io --all --timeout=180s || { echo "❌ Crossplane Providers failed."; exit 1; }
echo "⏳ Waiting for Crossplane Functions to become healthy..."
kubectl wait --for=condition=Healthy functions.pkg.crossplane.io --all --timeout=120s || { echo "❌ Crossplane Functions failed."; exit 1; }
echo "✅ Crossplane Providers & Functions Healthy."

# --- Step 2.8: Install Crossplane ProviderConfigs + RBAC (Layer 2.8) ---
# ProviderConfig CRDs are now registered (from providers above), safe to apply.
echo "🔧 [Layer 2.8] Installing Crossplane ProviderConfigs & RBAC..."
kubectl apply -f "$SCRIPT_DIR/platform/fundamentals/manifests/crossplane-configs.yaml"
echo "✅ Crossplane ProviderConfigs & RBAC applied."

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
kubectl apply -f "$SCRIPT_DIR/platform/root-app.yaml" -n argocd

echo "✅ Root Application applied. ArgoCD is now syncing from the internal Seed Gitea."

# --- Step 5: Initialize Garage S3 + Velero Credentials (Layer 5) ---
# Wait for ArgoCD to deploy Garage, then set up layout, API key, bucket, and Velero secret.
# Only runs for homelab target (Garage is homelab-specific).
if [[ "$TARGET" == "homelab" ]]; then
    # Prevent Git Bash (MSYS2) from converting /garage to C:/Program Files/Git/garage
    export MSYS_NO_PATHCONV=1

    echo "🗄️  [Layer 5] Initializing Garage S3 storage..."

    echo "⏳ Waiting for Garage pod to be Ready (ArgoCD must sync the Garage Application first)..."
    TIMEOUT=600
    START_TIME=$(date +%s)
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        if [ $ELAPSED -gt $TIMEOUT ]; then
            echo "⚠️  Timeout waiting for Garage. Skipping Garage/Velero init."
            echo "   Run this section manually later (see README.md)."
            break
        fi

        STATUS=$(kubectl get pods -n garage garage-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true

        if [[ "$STATUS" == "True" ]]; then
            echo "✅ Garage pod is Ready."

            # Wait a moment for all replicas to stabilize
            sleep 10

            # Get node IDs and assign layout
            echo "   Assigning Garage layout..."
            NODE_IDS=$(kubectl exec -n garage garage-0 -- /garage status 2>/dev/null | grep -oE '[0-9a-f]{16}' | head -10)
            if [[ -z "$NODE_IDS" ]]; then
                echo "⚠️  Could not parse Garage node IDs. Skipping layout init."
                break
            fi

            for NODE_ID in $NODE_IDS; do
                kubectl exec -n garage garage-0 -- /garage layout assign -z dc1 -c 1G "$NODE_ID" 2>/dev/null || true
            done

            # Apply layout (version 1 for fresh cluster)
            kubectl exec -n garage garage-0 -- /garage layout apply --version 1 2>/dev/null || {
                echo "⚠️  Layout apply failed (may already be applied). Continuing..."
            }
            echo "✅ Garage layout assigned."

            # Create API key for Velero
            echo "   Creating Garage API key for Velero..."
            KEY_OUTPUT=$(kubectl exec -n garage garage-0 -- /garage key create velero-service-key 2>/dev/null) || {
                echo "   Key may already exist, retrieving..."
                KEY_OUTPUT=$(kubectl exec -n garage garage-0 -- /garage key info velero-service-key 2>/dev/null) || {
                    echo "⚠️  Could not create or find Garage key. Skipping Velero credential setup."
                    break
                }
            }

            # Parse key ID and secret from output
            KEY_ID=$(echo "$KEY_OUTPUT" | grep -i "Key ID" | awk '{print $NF}')
            KEY_SECRET=$(echo "$KEY_OUTPUT" | grep -i "Secret" | awk '{print $NF}')

            if [[ -z "$KEY_ID" || -z "$KEY_SECRET" ]]; then
                echo "⚠️  Could not parse Garage key credentials. Skipping Velero setup."
                echo "   Key output was: $KEY_OUTPUT"
                break
            fi

            echo "   Key ID: $KEY_ID"

            # Create bucket
            echo "   Creating velero-backups bucket..."
            kubectl exec -n garage garage-0 -- /garage bucket create velero-backups 2>/dev/null || {
                echo "   Bucket may already exist. Continuing..."
            }

            # Grant access
            kubectl exec -n garage garage-0 -- /garage bucket allow velero-backups --read --write --key velero-service-key 2>/dev/null || true
            echo "✅ Garage bucket 'velero-backups' ready."

            # Create Velero credentials secret
            echo "   Creating Velero credentials secret..."
            kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
            kubectl create secret generic velero-credentials -n velero \
              --from-literal=cloud="[default]
aws_access_key_id=$KEY_ID
aws_secret_access_key=$KEY_SECRET" \
              --dry-run=client -o yaml | kubectl apply -f -
            echo "✅ Velero credentials secret created."
            break
        fi

        echo "   ... waiting for Garage pod ($ELAPSED/${TIMEOUT}s)"
        sleep 15
    done
else
    echo "ℹ️  Skipping Garage init (not homelab target)."
fi

echo "🎉 Bootstrap Complete!"
