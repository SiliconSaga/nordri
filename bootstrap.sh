#!/bin/bash
set -e

# Nordri Bootstrap Script
# Implements a layered infra build strategy:
# 1.   Assume existing Kubernetes cluster available via kubectl
# 2.   Install Seed Gitea + hydrate Nordri AND Nidavellir repos into it
# 2.5  Install Gateway API CRDs + Crossplane Core
# 2.6  Install Traefik (registers IngressRoute CRDs needed by ArgoCD)
# 2.7  Install Crossplane Providers + Functions, wait Healthy
# 2.8  Install Crossplane ProviderConfigs + RBAC
# 3.   Install ArgoCD
# 4.   Apply Root Application (ArgoCD adopts all pre-installed components)
# 5.   Initialize Garage S3 + Velero credentials (waits for ArgoCD to deploy Garage)
#
# After bootstrap, ArgoCD pulls both Nordri and Nidavellir from internal Gitea.
# See nidavellir/vegvisir/README.md for the procedure to switch to GitHub.
#
# Optional environment overrides:
#
#   GITEA_HOST  host:port for the Seed Gitea endpoint used by this script.
#               Default: "localhost:3000" — script will start a kubectl
#               port-forward to svc/gitea-http and push initial content via
#               that. Set to a public URL like "gitea.cmdbee.org" to skip
#               the port-forward (useful when re-running bootstrap on a
#               cluster that already has the Gitea HTTPRoute deployed, or
#               when localhost is intercepted by a git credential helper).
#   GITEA_SCHEME  http or https. Default: http. See update-embedded-git.sh
#               header for the full reasoning — short version is the
#               Gateway's websecure listener doesn't yet have a trusted
#               cert for cmdbee.org, so https reaches Traefik but is served
#               by a self-signed cert. Flip to https once the wildcard
#               cert is wired into the listener.
#
#   GITEA_USER  Admin username for Seed Gitea (default: nordri-admin).
#   GITEA_PASS  Admin password. Resolution order:
#                 • Explicit env var — wins. The script trusts that this
#                   matches what's in (or about to be in) Gitea, writes it
#                   to the Secret, and uses it for all in-script Gitea API
#                   calls. Use this on first run against a cluster that
#                   already has Gitea running with a known password (the
#                   common case for migration), or for any subsequent
#                   manual control. If the override doesn't match live
#                   Gitea, calls will fail loudly with 401, which is the
#                   right signal to surface a mismatch.
#                 • Otherwise, the gitea/gitea-admin-credentials Secret if
#                   it exists (idempotent re-run path).
#                 • Otherwise, a strong random password is generated.
#               After resolution, the Secret is rewritten to match.
#
#   NIDAVELLIR_DIR / MIMIR_DIR / HEIMDALL_DIR
#               Absolute path to each sibling component's checkout. Defaults
#               to ../<name> relative to this script.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=$1
# Capture explicit env-var input here without applying defaults — that lets
# resolve_gitea_credentials() distinguish "user explicitly set this" from
# "we should fall back to Secret / Helm state / generation". Defaults apply
# inside the resolver. See the Optional environment overrides block in the
# header.
GITEA_USER="${GITEA_USER:-}"
GITEA_PASS="${GITEA_PASS:-}"
GITEA_HOST="${GITEA_HOST:-localhost:3000}"
GITEA_SCHEME="${GITEA_SCHEME:-http}"
GITEA_REPO_NAME="nordri"
NIDAVELLIR_GITEA_REPO="nidavellir"
MIMIR_GITEA_REPO="mimir"
HEIMDALL_GITEA_REPO="heimdall"
# Where the Gitea admin credentials live in-cluster.
GITEA_CREDENTIALS_NAMESPACE="gitea"
GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
# Sibling directories expected alongside this repo. Override with env vars.
NIDAVELLIR_DIR="${NIDAVELLIR_DIR:-$(dirname "$SCRIPT_DIR")/nidavellir}"
MIMIR_DIR="${MIMIR_DIR:-$(dirname "$SCRIPT_DIR")/mimir}"
HEIMDALL_DIR="${HEIMDALL_DIR:-$(dirname "$SCRIPT_DIR")/heimdall}"
INTERNAL_GITEA_URL="http://gitea-http.gitea.svc.cluster.local:3000"

if [[ -z "$TARGET" ]]; then
    echo "Usage: ./bootstrap.sh [gke|homelab]"
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
# This is the SEED instance — intentionally minimal and ephemeral. It exists solely
# to host the Nordri + Nidavellir repos so ArgoCD has a GitOps source during bootstrap.
# It runs with persistence.enabled=false and uses the chart's bundled Postgres + Valkey.
#
# TODO: After Mimir is stable, harden Gitea into a proper platform component:
#   - See nidavellir/docs/platform-gitea.md for design notes.
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

# Resolve Gitea admin credentials before installing the chart. Username and
# password are resolved independently from explicit env vars and the
# in-cluster Secret.
#
# Username priority:  GITEA_USER env  >  Secret  >  "nordri-admin"
# Password priority:  GITEA_PASS env  >  Secret  >  freshly-generated random
#
# The script trusts whatever the resolver picks and writes it to the Secret
# unconditionally. If the user supplies GITEA_PASS that disagrees with live
# Gitea (the Helm chart preserves the existing admin user on upgrade), the
# Secret captures the user's stated intent — subsequent script invocations
# will fail loudly when authentication fails, which is the correct way to
# surface a mismatch. To rotate: change the password in Gitea (UI/API),
# then re-run this script with GITEA_PASS=<new> (or update the Secret
# directly with kubectl). See README.md "Credentials" for the full flow.
resolve_gitea_credentials() {
    local explicit_user="$GITEA_USER"
    local explicit_pass="$GITEA_PASS"
    local secret_user=""
    local secret_pass=""

    if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        secret_user="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.username}' | base64 --decode)"
        secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
    fi

    # Username
    if [[ -n "$explicit_user" ]]; then
        GITEA_USER="$explicit_user"
    elif [[ -n "$secret_user" ]]; then
        GITEA_USER="$secret_user"
    else
        GITEA_USER="nordri-admin"
    fi

    # Password
    if [[ -n "$explicit_pass" ]]; then
        GITEA_PASS="$explicit_pass"
        echo "🔑 Using GITEA_PASS from environment (user: $GITEA_USER)."
    elif [[ -n "$secret_pass" ]]; then
        GITEA_PASS="$secret_pass"
        echo "🔑 Loaded Gitea password from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
    else
        # Fresh install (or first run that just lacks both env var and Secret):
        # generate a strong random password. `openssl rand -base64 24` = 24
        # random bytes → 32 base64 chars; we strip the symbol chars (/, +, =)
        # and trim to 24 chars from the remaining 62-symbol alphabet, giving
        # ~143 bits of effective entropy — plenty for a service account.
        GITEA_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
        echo "🔑 Generated random Gitea admin password (user: $GITEA_USER, will be stored in $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET)."
    fi
}
resolve_gitea_credentials

# Persist the active credentials to the Secret. Idempotent.
kubectl create secret generic "$GITEA_CREDENTIALS_SECRET" \
    -n "$GITEA_CREDENTIALS_NAMESPACE" \
    --from-literal=username="$GITEA_USER" \
    --from-literal=password="$GITEA_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Now that user/pass are settled, build the URL bases reused below.
# `git remote add` requires the credentials embedded in the URL — so we
# percent-encode user/pass to handle special chars (@, :, /, #) without
# corrupting the URL. API calls go through curl -u instead and just use
# the credentials-less base URL.
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
GITEA_USER_ENC="$(urlencode "$GITEA_USER")"
GITEA_PASS_ENC="$(urlencode "$GITEA_PASS")"
GITEA_API_URL="${GITEA_SCHEME}://${GITEA_HOST}"
GITEA_GIT_BASE="${GITEA_SCHEME}://${GITEA_USER_ENC}:${GITEA_PASS_ENC}@${GITEA_HOST}"
GITEA_PROBE_URL="${GITEA_API_URL}/api/v1/version"

# Probe the Gitea endpoint. Returns 0 if Gitea answers /api/v1/version
# with HTTP 200. Used to confirm we're talking to actual Gitea, not just
# any service that happens to be on this host:port.
probe_gitea() {
    curl -fsS --max-time 5 "$GITEA_PROBE_URL" >/dev/null 2>&1
}

# We use a simple configuration for the seed instance
helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --set-string gitea.admin.username="$GITEA_USER" \
  --set-string gitea.admin.password="$GITEA_PASS" \
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

# Reach the Seed Gitea endpoint. By default that's localhost:3000 via a
# kubectl port-forward; if GITEA_HOST is overridden (e.g. gitea.cmdbee.org
# on a re-bootstrap of an existing cluster that already has the HTTPRoute
# wired up), skip the port-forward and use the URL directly. Either way,
# probe Gitea before continuing so we don't push credentials at a wrong
# endpoint or an unready ingress.
if [[ "$GITEA_HOST" == "localhost:3000" ]]; then
    if probe_gitea; then
        # Re-runs may already have a port-forward (or some other localhost
        # listener serving Gitea); reuse it instead of stacking another
        # background process.
        echo "   Reusing existing Gitea endpoint at $GITEA_HOST."
    else
        kubectl port-forward svc/gitea-http -n gitea 3000:3000 > /dev/null 2>&1 &
        PF_PID=$!
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

# Create a Gitea repo via API with retry. Gitea's ephemeral mode can fail on rapid
# sequential repo creates (initRepository race). We check the response body for errors.
create_gitea_repo() {
    local repo_name=$1
    local max_retries=5
    for i in $(seq 1 $max_retries); do
        # `-u user:pass` keeps credentials out of the URL so special chars
        # in GITEA_PASS (@, :, /, #) can't corrupt URL parsing.
        RESPONSE=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
          -X POST "$GITEA_API_URL/api/v1/user/repos" \
          -H "Content-Type: application/json" \
          -d "{\"name\": \"$repo_name\", \"private\": false}")

        # Check if response contains a valid repo (has "clone_url") or already-exists error
        if echo "$RESPONSE" | grep -q '"clone_url"'; then
            echo "   Created repo: $repo_name"
            return 0
        elif echo "$RESPONSE" | grep -q 'already exists'; then
            echo "   Repo $repo_name already exists."
            return 0
        else
            echo "   Repo creation attempt $i/$max_retries failed for $repo_name: $(echo "$RESPONSE" | head -c 120)"
            sleep 5
        fi
    done
    echo "❌ Failed to create repo $repo_name after $max_retries attempts."
    return 1
}

# Create all repos upfront (sequential with retry to avoid Gitea init races)
create_gitea_repo "$GITEA_REPO_NAME"

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

# Push Nordri to Gitea
cd $HYDRATE_DIR
git init
git config user.email "bootstrap@nordri.local"
git config user.name "Nordri Bootstrap"
git checkout -b main
git add .
git commit -m "Hydration for $TARGET"
git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$GITEA_REPO_NAME.git"
git push -u origin main --force
cd -
# `git remote add` writes the admin password into .git/config; don't leave
# that lying around on disk after the push completes.
rm -rf "$HYDRATE_DIR"

echo "✅ Nordri configuration hydrated to Seed Gitea."

# Also push Nidavellir to Gitea so ArgoCD can manage Vegvísir (Gateway + TLS).
# ArgoCD pulls from internal Gitea during bootstrap; can be swapped to GitHub later.
# See nidavellir/vegvisir/README.md for the transition procedure.
if [[ -d "$NIDAVELLIR_DIR" ]]; then
    echo "💧 [Layer 2] Hydrating Nidavellir to Seed Gitea..."

    create_gitea_repo "$NIDAVELLIR_GITEA_REPO"

    NIDAVELLIR_HYDRATE=$(mktemp -d)
    cp -r "$NIDAVELLIR_DIR/." "$NIDAVELLIR_HYDRATE/"
    rm -rf "$NIDAVELLIR_HYDRATE/.git"  # Don't push source .git dir

    cd "$NIDAVELLIR_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Bootstrap"
    git checkout -b main
    git add .
    git commit -m "Hydration for $TARGET"
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$NIDAVELLIR_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$NIDAVELLIR_HYDRATE"

    echo "✅ Nidavellir hydrated to Seed Gitea."
else
    echo "⚠️  Nidavellir directory not found at: $NIDAVELLIR_DIR"
    echo "   Set NIDAVELLIR_DIR env var or clone nidavellir as a sibling of this repo."
    echo "   Vegvísir (Gateway + TLS) will not be deployed until Nidavellir is available."
fi

# Also push Mimir to Gitea so ArgoCD can deploy data service operators + XRDs.
# Mimir is referenced by nidavellir/apps/mimir-app.yaml (sync-wave 6).
if [[ -d "$MIMIR_DIR" ]]; then
    echo "💧 [Layer 2] Hydrating Mimir to Seed Gitea..."

    create_gitea_repo "$MIMIR_GITEA_REPO"

    MIMIR_HYDRATE=$(mktemp -d)
    cp -r "$MIMIR_DIR/." "$MIMIR_HYDRATE/"
    rm -rf "$MIMIR_HYDRATE/.git"  # Don't push source .git dir

    cd "$MIMIR_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Bootstrap"
    git checkout -b main
    git add .
    git commit -m "Hydration for $TARGET"
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$MIMIR_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$MIMIR_HYDRATE"

    echo "✅ Mimir hydrated to Seed Gitea."
else
    echo "⚠️  Mimir directory not found at: $MIMIR_DIR"
    echo "   Set MIMIR_DIR env var or clone mimir as a sibling of this repo."
    echo "   Data services will not be deployed until Mimir is available."
fi

# Also push Heimdall to Gitea so ArgoCD can deploy the observability stack.
# Heimdall is referenced by nidavellir/apps/heimdall-app.yaml (sync-wave 10).
if [[ -d "$HEIMDALL_DIR" ]]; then
    echo "💧 [Layer 2] Hydrating Heimdall to Seed Gitea..."

    create_gitea_repo "$HEIMDALL_GITEA_REPO"

    HEIMDALL_HYDRATE=$(mktemp -d)
    cp -r "$HEIMDALL_DIR/." "$HEIMDALL_HYDRATE/"
    rm -rf "$HEIMDALL_HYDRATE/.git"  # Don't push source .git dir

    cd "$HEIMDALL_HYDRATE"
    git init
    git config user.email "bootstrap@nordri.local"
    git config user.name "Nordri Bootstrap"
    git checkout -b main
    git add .
    git commit -m "Hydration for $TARGET"
    git remote add origin "$GITEA_GIT_BASE/$GITEA_USER/$HEIMDALL_GITEA_REPO.git"
    git push -u origin main --force
    cd -
    rm -rf "$HEIMDALL_HYDRATE"

    echo "✅ Heimdall hydrated to Seed Gitea."
else
    echo "⚠️  Heimdall directory not found at: $HEIMDALL_DIR"
    echo "   Set HEIMDALL_DIR env var or clone heimdall as a sibling of this repo."
    echo "   Observability stack will not be deployed until Heimdall is available."
fi

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
  --set gateway.enabled=false \
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
kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd --namespace argo \
  --set dex.enabled=false \
  --set server.insecure=true \
  --set server.extraArgs={--insecure} \
  --set configs.cm."kustomize\.buildOptions"="--load-restrictor LoadRestrictionsNone --enable-helm"

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
    STATUS=$(kubectl get pods -n argo -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$STATUS" == "True" ]]; then
        echo "✅ ArgoCD Server is Ready."
        break
    fi

    echo "   ... waiting for ArgoCD Server ($ELAPSED/${TIMEOUT}s)"
    kubectl logs -n argo -l app.kubernetes.io/name=argocd-server --tail=1 2>/dev/null || true
    
    sleep 5
done

echo "✅ ArgoCD installed."

# --- Step 4: Configure ArgoCD Source ---
echo "🔗 [Layer 3] Connecting Argo to Seed Gitea..."

# Since Gitea and Argo are in the same cluster, Argo can talk to Gitea via K8s DNS
# We assume the repo is public inside the cluster for read access, or we configure creds

# Apply the Root App
echo "🌱 [Layer 4] Applying Root Application..."
kubectl apply -f "$SCRIPT_DIR/platform/root-app.yaml" -n argo

echo "✅ Root Application applied. ArgoCD is now syncing from the internal Seed Gitea."

# --- GKE: Pre-create Velero namespace + dummy credentials ---
# Velero's Helm chart requires the velero-credentials secret to exist before the pod
# starts. ArgoCD begins syncing Velero immediately after the root app is applied, so
# we create a placeholder secret now to prevent a CrashLoopBackOff.
#
# TODO: Replace this block with proper GCS + Workload Identity setup.
# When done, no secret will be needed at all (useSecret: false in velero-gke.yaml).
# See docs/velero-gke.md for the full implementation plan.
if [[ "$TARGET" == "gke" ]]; then
    echo "🔑 [GKE] Pre-creating Velero namespace and placeholder credentials..."
    kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic velero-credentials -n velero \
      --from-literal=cloud="[default]
aws_access_key_id=PLACEHOLDER
aws_secret_access_key=PLACEHOLDER" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Velero placeholder credentials created (temporary — see docs/velero-gke.md)."
fi

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

# --- Step 6: Post-Bootstrap Instructions (GKE) ---
if [[ "$TARGET" == "gke" ]]; then
    echo ""
    echo "⏳ [Post-Bootstrap] Waiting for Traefik LoadBalancer IP..."
    TIMEOUT=180
    START_TIME=$(date +%s)
    TRAEFIK_IP=""
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        if [ $ELAPSED -gt $TIMEOUT ]; then
            echo "⚠️  Timeout waiting for Traefik LoadBalancer IP."
            TRAEFIK_IP="<pending — run: kubectl get svc traefik -n kube-system>"
            break
        fi

        TRAEFIK_IP=$(kubectl get svc traefik -n kube-system \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

        if [[ -n "$TRAEFIK_IP" ]]; then
            echo "✅ Traefik LoadBalancer IP: $TRAEFIK_IP"
            break
        fi

        echo "   ... waiting for GKE to assign LoadBalancer IP ($ELAPSED/${TIMEOUT}s)"
        sleep 10
    done

    # --- DNS Automation (optional — requires NameCheap credentials) ---
    # Set NAMECHEAP_API_USER and NAMECHEAP_API_KEY to automate A record updates.
    # See scripts/update-dns-namecheap.sh for one-time NameCheap setup instructions.
    DNS_UPDATED=false
    if [[ -n "${NAMECHEAP_API_KEY:-}" ]]; then
        echo ""
        echo "🔧 [DNS] NameCheap credentials detected — attempting automated DNS update..."
        if "$SCRIPT_DIR/scripts/update-dns-namecheap.sh" \
             "${NAMECHEAP_DOMAIN:-cmdbee.org}" "$TRAEFIK_IP"; then
            DNS_UPDATED=true
        else
            echo "⚠️  DNS automation failed. Follow manual instructions below."
        fi
    fi

    if [[ "$DNS_UPDATED" == "false" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              📋 MANUAL STEPS REQUIRED                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  ArgoCD is now syncing. Two manual steps remain:                 ║"
    echo "║                                                                  ║"
    echo "║  1. Point your domain(s) at the Traefik LoadBalancer:            ║"
    echo "║                                                                  ║"
    echo "║     <your-domain>  →  A record  →  $TRAEFIK_IP                   ║"
    echo "║                                                                  ║"
    echo "║     Add A records (and wildcards) at your DNS registrar.         ║"
    echo "║     cert-manager will issue certs once DNS propagates.           ║"
    echo "║                                                                  ║"
    echo "║  2. cert-manager + issuers deploy automatically via ArgoCD:      ║"
    echo "║     • cert-manager operator installs first                       ║"
    echo "║     • traefik-gateway applies and registers its Listener         ║"
    echo "║     • letsencrypt-gateway (staging & prod) Issuers register      ║"
    echo "║     Monitor: kubectl get applications -n argo                     ║"
    echo "║                                                                  ║"
    echo "║  3. Use letsencrypt-gateway-staging to validate the pipeline     ║"
    echo "║     before requesting production certs. Staging certs are        ║"
    echo "║     untrusted by browsers but confirm the full ACME flow.        ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    fi   # DNS_UPDATED
fi

echo "🎉 Bootstrap Complete!"
