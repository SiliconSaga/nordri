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
# 5.   Initialize Garage S3 + Velero and OpenBao-snapshot credentials (waits
#      for ArgoCD to deploy Garage)
# 5b.  OpenBao: init + unseal (homelab; gke only with OPENBAO_AUTO_INIT=1), the
#      one-time KV/auth/policy configuration ESO needs, realm-declared seeds
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
#   HYDRATE_URL_MODE  seed (default) | forgejo | swap. Which repoURL form the
#               hydrated manifests carry — see lib/patch-urls.sh. bootstrap
#               always wants `seed`; the other modes exist for the Forgejo
#               graduation flow (realm Forgejo day-2 design, Phase 3).
#
#   NIDAVELLIR_DIR / MIMIR_DIR / HEIMDALL_DIR
#               Absolute path to each sibling component's checkout. Defaults
#               to ../<name> relative to this script.
#
#   OPENBAO_AUTO_INIT  Set to 1 to let Layer 5b init and unseal OpenBao on gke
#               too, parking the shares in-cluster. Default: homelab only —
#               on a live environment the shares belong in the password
#               manager first (nidavellir docs/secrets-management.md).
#   OPENBAO_SEEDS_FILE Path to the realm's seed declaration. Default:
#               <REALM_DIR>/openbao-seeds when a realm is given; see
#               lib/openbao.sh for the one-line-per-path format.
#
#   KUBE_CONTEXT  Optional. The kubectl context this run is for; the script
#               refuses to start if the current context differs (it never
#               switches contexts itself). Set or not, a gke target requires a
#               gke_* context and a homelab target refuses one — see
#               lib/kube-context.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Helm 4 applies server-side by default, and a RE-RUN on a cluster where ArgoCD
# has since adopted these releases (Layer 4) then fails with a field-manager
# conflict on whatever ArgoCD last wrote — seen 2026-09-16 on Traefik's
# container args, which stopped an otherwise idempotent re-run at Layer 2.6.
# Forcing the conflict makes bootstrap's values win for a moment; ArgoCD's
# self-heal reconciles its own values back within its sync interval, which is
# exactly what helm 3's client-side three-way merge did without saying so.
# Helm 3 has no such flag, so it is added only on helm 4+.
HELM_APPLY_FLAGS=()
case "$(helm version --template '{{.Version}}' 2>/dev/null)" in
    v[4-9].*) HELM_APPLY_FLAGS=(--force-conflicts) ;;
esac
# Shared hydration libraries (extracted from the duplicated inline blocks).
. "$SCRIPT_DIR/lib/gitea.sh"
. "$SCRIPT_DIR/lib/hydrate.sh"
. "$SCRIPT_DIR/lib/patch-nidavellir.sh"
. "$SCRIPT_DIR/lib/patch-velero.sh"
. "$SCRIPT_DIR/lib/patch-urls.sh"
. "$SCRIPT_DIR/lib/openbao.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"
TARGET=$1
# Capture explicit GITEA_PASS env input here without applying a default —
# the resolver populates the value below. Username is fixed to
# "nordri-admin" inside the resolver (downstream ArgoCD Application
# repoURLs hardcode that literal, so any drift would break sync); only
# password accepts an env override.
GITEA_PASS="${GITEA_PASS:-}"
GITEA_HOST="${GITEA_HOST:-localhost:3000}"
GITEA_SCHEME="${GITEA_SCHEME:-http}"
# Guard: the kubectl port-forward target (svc/gitea-http) only speaks plain
# HTTP, so GITEA_SCHEME=https against localhost:3000 will fail. Force http
# and warn loudly if the caller mistakenly mixed them.
if [[ "$GITEA_HOST" == "localhost:3000" && "$GITEA_SCHEME" != "http" ]]; then
    echo "⚠️  Ignoring GITEA_SCHEME=$GITEA_SCHEME with default localhost:3000 — the port-forwarded gitea-http service is HTTP-only. Forcing http."
    GITEA_SCHEME="http"
fi
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
# Fresh-cluster bootstrap: repos are created with auto_init so ArgoCD can
# resolve HEAD. The working-tree hydration helper reads this.
HYDRATE_AUTO_INIT=true
# Vendored upstream mirrors to push (real history + tags) so in-cluster apps can
# pin exact upstream refs. Space-separated component dir names; same default as
# update-embedded-git.sh.
VENDOR_MIRRORS="${VENDOR_MIRRORS:-keycloak-k8s-resources}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: ./bootstrap.sh [gke|homelab] [realm]"
    exit 1
fi

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Error: Target must be 'gke' or 'homelab'"
    exit 1
fi

# Every kubectl below follows the kubeconfig's current context, not the ws k8s
# guard scope — refuse now if that context does not fit the target.
require_kube_context "$TARGET" || exit 1

# Optional owning realm (arg 2): a realm whose cluster/ subtree carries
# realm-owned in-cluster config (e.g. the siliconsaga keycloak realm-import).
# Omit it for a generic demo-only stack. REALM_DIR overrides the default
# <workspace>/realms/<realm> resolution (nordri lives at <workspace>/components/nordri).
REALM="${2:-}"
if [[ -n "$REALM" ]]; then
    if [[ ! "$REALM" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || [[ ${#REALM} -gt 63 ]]; then
        echo "❌ Realm '$REALM' must be a DNS-1123 label (lowercase alphanumeric and '-', max 63 chars) — it names a Gitea repo and a Kubernetes Application." >&2
        exit 1
    fi
fi
REALM_DIR="${REALM_DIR:-}"
if [[ -n "$REALM" && -z "$REALM_DIR" ]]; then
    REALM_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$REALM"
fi
if [[ -n "$REALM" && ! -d "$REALM_DIR/cluster" ]]; then
    echo "❌ Owning realm '$REALM' has no cluster/ config at: $REALM_DIR/cluster" >&2
    echo "   Pass a realm whose repo carries cluster/, set REALM_DIR, or omit the arg for demo-only." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "❌ This script requires 'jq' on PATH (used to URL-encode Gitea credentials)." >&2
    echo "   Install with: 'apt install jq' / 'brew install jq' / 'choco install jq'." >&2
    exit 1
}

echo "🚀 Bootstrapping Nordri for target: $TARGET"

# --- Step 0: Pre-flight Checks (Rancher Desktop Specifics) ---
# Only relevant when the TARGET is the local Rancher Desktop VM (homelab path).
# `rdctl` may be installed on a workstation that's also being used to bootstrap
# a remote cluster (e.g. GKE) — in that case the VM preflight is meaningless
# and `rdctl shell` would target the wrong machine.
if [[ "$TARGET" == "homelab" ]] && command -v rdctl &> /dev/null; then
    echo "🔍 Detected Rancher Desktop (rdctl). Checking for required VM dependencies..."
    # Check for iscsiadm. Added for Longhorn, which was retired 2026-08-26, so
    # nothing we deploy needs it today. Kept because any distributed storage we
    # adopt later (Longhorn, Rook-Ceph) will want it, and installing it is cheap
    # and idempotent — but it is a preflight for a future component, not a
    # current one.
    if ! rdctl shell which iscsiadm >/dev/null 2>&1; then
        echo "⚠️  'iscsiadm' missing in Rancher Desktop VM. Installing open-iscsi..."
        # `rdctl shell` invokes commands via nsenter, not a shell — so compound
        # commands (&&, |, ;) must be wrapped in `sh -c` to be parsed.
        rdctl shell sh -c "sudo apk update && sudo apk add open-iscsi && sudo rc-service iscsid start"
        echo "✅ Installed open-iscsi."
    else
         echo "✅ 'iscsiadm' found in VM."
    fi
fi

# --- Step 0b: the storage class cluster-identity names (homelab) ---
# cluster-identity-homelab.yaml pins `storageClass: local-path`, the name k3s
# and Rancher Desktop ship. Docker Desktop's built-in Kubernetes runs the SAME
# rancher.io/local-path provisioner but calls its classes `standard` and
# `hostpath`, so on that host every PVC in the stack would sit Pending with
# no event that names the cause. A StorageClass is only a name bound to a
# provisioner and a policy, so alias the cluster's default provisioner under
# the name the identity promises rather than teach every composition a
# second name per host. No-op where `local-path` already exists.
if [[ "$TARGET" == "homelab" ]]; then
    if kubectl get storageclass local-path >/dev/null 2>&1; then
        echo "✅ StorageClass local-path present."
    else
        # One name per line, so several defaults (a misconfiguration Kubernetes
        # tolerates) are counted rather than concatenated into one bad argument.
        DEFAULT_SCS="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')"
        DEFAULT_SC_COUNT="$(printf '%s' "$DEFAULT_SCS" | grep -c .)" || DEFAULT_SC_COUNT=0
        if [[ "$DEFAULT_SC_COUNT" -eq 0 ]]; then
            echo "❌ No StorageClass named local-path and no default StorageClass to alias it to." >&2
            echo "   cluster-identity-homelab.yaml expects local-path; create it (or a default class) and re-run." >&2
            exit 1
        elif [[ "$DEFAULT_SC_COUNT" -gt 1 ]]; then
            echo "❌ No StorageClass named local-path, and more than one class is marked default:" >&2
            printf '   %s\n' $DEFAULT_SCS >&2
            echo "   Kubernetes picks between them by creation time, which is not a choice to encode here. Keep one default and re-run." >&2
            exit 1
        fi
        DEFAULT_SC="$DEFAULT_SCS"
        DEFAULT_PROVISIONER="$(kubectl get storageclass "$DEFAULT_SC" -o jsonpath='{.provisioner}')"
        echo "🗄️  No StorageClass local-path — aliasing default class '$DEFAULT_SC' (provisioner $DEFAULT_PROVISIONER) under that name..."
        kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    nordri.siliconsaga.org/aliases: "$DEFAULT_SC"
provisioner: $DEFAULT_PROVISIONER
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        echo "✅ StorageClass local-path created."
    fi
fi

# --- Step 1: Install Seed Gitea (Layer 2) ---
# This is the SEED instance — intentionally minimal and ephemeral. It exists solely
# to host the Nordri + Nidavellir repos so ArgoCD has a GitOps source during bootstrap.
#
# It runs SQLite with in-memory cache/session and a level queue, and that is a
# deliberate downgrade from what this script used to install.
#
# `persistence.enabled=false` only disables GITEA's own volume. The chart's
# subchart defaults are `postgresql-ha.enabled=true` and
# `valkey-cluster.enabled=true`, so an install that set nothing else quietly
# brought up EIGHT pods for a disposable seed: a 3-replica Postgres with pgpool
# and a 3-node Valkey cluster. Measured on the SiliconSaga cluster 2026-09-03:
# 1300m of CPU requests — more than Artifactory itself asks for, ~11% of the
# whole cluster — plus 54Gi of PVCs, none of which `persistence.enabled=false`
# touches. On a cluster sitting at ~94% CPU requests that is real money.
#
# ⚠ Disabling the subcharts is NOT sufficient on its own. The chart's helper
# only ever auto-sets DB_TYPE=postgres; with both Postgres options off and no
# explicit DB_TYPE, Gitea comes up with no database configured. The four
# gitea.config settings below are required alongside the four `enabled=false`
# flags, and this combination is what the chart's own README documents for an
# ephemeral install.
#
# ⚠ Do NOT try to thin this by scaling replicas instead. Valkey runs in CLUSTER
# mode, which shards 16384 hash slots across its masters — scaling it to 1 leaves
# ~2/3 of the slots unreachable and the cluster reports `cluster_state:fail`.
# (Postgres is repmgr primary/standby and does scale down safely; Valkey does
# not. They look alike and are not.) Turn cluster mode off, do not shrink it.
#
# TODO: After Mimir is stable, harden Gitea into a proper platform component:
#   - See nidavellir/docs/platform-gitea.md for design notes.
#   - Forgejo is the intended path for persistent GitOps; this seed should stay
#     disposable rather than growing into the durable thing.
echo "📦 [Layer 2] Installing Seed Gitea..."
helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null 2>&1
helm repo update
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -

# We use a simple configuration for the seed instance.
#
# Cleanup runs on every script exit (success or failure) — kills the
# port-forward and removes any temp hydration dirs we registered. The
# temp dirs hold the Nordri/Nidavellir/Mimir/Heimdall checkouts that
# get pushed to Gitea, and `git remote add` writes the embedded admin
# password into each one's .git/config. Without trap-based cleanup,
# `set -e` exits before the success-path `rm -rf` runs on a push
# failure, leaving credentials on disk.
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

# Resolve Gitea admin credentials before installing the chart.
#
# Password priority:  GITEA_PASS env  >  Secret  >  random (only when this
#                     looks like a fresh install)
# Username:           always "nordri-admin" — downstream ArgoCD app
#                     repoURLs hardcode this, so any drift would break
#                     ArgoCD sync. The Secret records the username for
#                     introspection but the script never reads it back.
#
# Existing-cluster guard: if a Helm release named 'gitea' is already
# present and we'd otherwise generate a fresh random password (no env
# var, no Secret), we refuse to proceed. The Helm chart preserves the
# admin user on upgrade, so generating a random and writing it to the
# Secret would create a silent mismatch with live Gitea. Caller must
# pass GITEA_PASS=<live> as the one-shot migration command. Once the
# Secret exists, normal idempotent re-runs work.
#
# To rotate: change the password in Gitea (UI/API), then re-run this
# script with GITEA_PASS=<new> (or update the Secret directly with
# kubectl). See README.md "Credentials" for the full flow.
resolve_gitea_credentials() {
    local explicit_pass="$GITEA_PASS"
    local secret_pass=""

    if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
    fi

    # Username is fixed (see header comment).
    GITEA_USER="nordri-admin"

    # Password
    if [[ -n "$explicit_pass" ]]; then
        GITEA_PASS="$explicit_pass"
        echo "🔑 Using GITEA_PASS from environment (user: $GITEA_USER)."
    elif [[ -n "$secret_pass" ]]; then
        GITEA_PASS="$secret_pass"
        echo "🔑 Loaded Gitea password from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
    elif helm status gitea -n "$GITEA_CREDENTIALS_NAMESPACE" >/dev/null 2>&1; then
        echo "❌ Existing Gitea release in '$GITEA_CREDENTIALS_NAMESPACE' but no $GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
        echo "   Generating a random password here would silently disagree with the live admin user (the Helm chart preserves it on upgrade)." >&2
        echo "   Re-run with the live password to migrate this cluster:" >&2
        echo "     GITEA_PASS=<live-password> $0 $TARGET" >&2
        exit 1
    else
        # Fresh install: generate a strong random password.
        # `openssl rand -base64 24` = 24 random bytes → 32 base64 chars; we
        # strip the symbol chars (/, +, =) and trim to 24 chars from the
        # remaining 62-symbol alphabet, giving ~143 bits of effective
        # entropy — plenty for a service account.
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
gitea_build_urls

# We use a simple configuration for the seed instance
helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --set-string gitea.admin.username="$GITEA_USER" \
  --set-string gitea.admin.password="$GITEA_PASS" \
  --set persistence.enabled=false \
  --set postgresql-ha.enabled=false \
  --set postgresql.enabled=false \
  --set valkey-cluster.enabled=false \
  --set valkey.enabled=false \
  --set gitea.config.database.DB_TYPE=sqlite3 \
  --set gitea.config.session.PROVIDER=memory \
  --set gitea.config.cache.ADAPTER=memory \
  --set gitea.config.queue.TYPE=level \
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
TEMP_DIRS+=("$HYDRATE_DIR")
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

# gitea_ensure_repo (create-if-missing; auto_init for fresh repos) lives in lib/gitea.sh.

# Create all repos upfront (sequential with retry to avoid Gitea init races)
gitea_ensure_repo "$GITEA_REPO_NAME" true

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

# Stamp the GCP project into the Velero Application (GKE only; no-op for
# homelab). Committing a bare placeholder keeps the repo free of any one
# project's identity — the value exists only in the hydrated copy pushed to the
# Seed Gitea. Shared with update-embedded-git.sh; see lib/patch-velero.sh.
patch_velero_tree "$HYDRATE_DIR" "$TARGET" || exit 1

# Copy the root application — BEFORE the URL rewrite below, so it is covered.
cp "$SCRIPT_DIR/platform/root-app.yaml" "$HYDRATE_DIR/"

# Rewrite committed Forgejo repoURLs to the seed form. A no-op until the
# manifests move to the durable form (realm Forgejo day-2 design, Phase 3).
patch_repo_urls_tree "$HYDRATE_DIR" "${HYDRATE_URL_MODE:-seed}" >/dev/null || exit 1

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
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$NIDAVELLIR_GITEA_REPO" "Hydration for $TARGET" patch_nidavellir_tree

# Also push Mimir to Gitea so ArgoCD can deploy data service operators + XRDs.
# Mimir is referenced by nidavellir/apps/mimir-app.yaml (sync-wave 6).
hydrate_working_tree_repo "$MIMIR_DIR" "$MIMIR_GITEA_REPO" "Hydration for $TARGET"

# Also push Heimdall to Gitea so ArgoCD can deploy the observability stack.
# Heimdall is referenced by nidavellir/apps/heimdall-app.yaml (sync-wave 10).
hydrate_working_tree_repo "$HEIMDALL_DIR" "$HEIMDALL_GITEA_REPO" "Hydration for $TARGET"

# Vendor mirrors: push real history + tags so in-cluster apps can pin exact
# upstream refs (e.g. keycloak-operator pins tag 26.6.3). Also run day-2 by
# update-embedded-git.sh; running it here makes a fresh bootstrap reproducible.
hydrate_vendor_mirrors "$VENDOR_MIRRORS"

# Owning realm (optional): hydrate its cluster/ subtree so ArgoCD can sync
# realm-owned config. The realm root-app that points ArgoCD at it is registered
# after ArgoCD is installed (see the realm root-app step below).
if [[ -n "$REALM" ]]; then
    hydrate_working_tree_repo "$REALM_DIR/cluster" "$REALM" "Realm config for $TARGET"
fi

# --- Step 2.5: Install Crossplane Core (Layer 2.5) ---
# Gateway API CRDs were installed here in earlier versions, but Traefik chart
# 38+ bundles its own copy alongside IngressRoute/Middleware CRDs. Applying
# them ourselves with `kubectl apply` (client-side, field-manager
# `kubectl-client-side-apply`) caused a field-manager conflict on first
# `helm install traefik`. We now let the Traefik chart in Layer 2.6 install
# the Gateway API CRDs; the verify step moves with them.
echo "✈️ [Layer 2.5] Installing Crossplane Core..."
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1
helm repo update

# We install the full Crossplane Core here to ensure CRDs (Composition, Provider, etc.) are established.
# ArgoCD will later adopt this release because we use the same release name and namespace.
helm upgrade --install crossplane crossplane-stable/crossplane "${HELM_APPLY_FLAGS[@]}" \
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

helm upgrade --install traefik traefik/traefik "${HELM_APPLY_FLAGS[@]}" \
  --namespace kube-system \
  --version 38.0.1 \
  --set providers.kubernetesGateway.enabled=true \
  --set gateway.enabled=false \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443

echo "⏳ Waiting for Traefik to become ready..."
kubectl rollout status deployment/traefik -n kube-system --timeout=120s || { echo "❌ Traefik failed to start."; exit 1; }

echo "   Verifying Gateway API CRDs (installed by Traefik chart)..."
# Wait on the three CRDs the downstream Vegvísir stack actually consumes:
# GatewayClass + Gateway + HTTPRoute. The chart could partially install
# (e.g. version skew, hook failure) and a single-CRD check would miss it.
kubectl wait --for=condition=established --timeout=30s \
    crd/gatewayclasses.gateway.networking.k8s.io \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io || { echo "❌ Gateway API CRDs missing after Traefik install"; exit 1; }
echo "✅ Traefik Installed (Gateway API + IngressRoute CRDs available)."

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

# --- Step 2.9: OpenBao seal key (homelab only) ---
# Homelab OpenBao unseals with a STATIC key (realm ADR 0004): 32 random bytes
# held in a Secret the composition injects as BAO_SEAL_STATIC_KEY. Created here,
# once, if absent — a composition cannot generate random material (every
# reconcile would re-render a different key and permanently seal the vault).
# GKE needs nothing here: it seals through KMS via Workload Identity, set up by
# `gke-provision.sh openbao-seal-setup`.
#
# The Secret must exist BEFORE the OpenBao pod is created; an env var sourced
# from a missing Secret leaves the pod in CreateContainerConfigError. ArgoCD
# deploys OpenBao at wave 10, long after this point.
if [[ "$TARGET" == "homelab" ]]; then
    echo "🔐 [Layer 2.9] Ensuring the homelab OpenBao static seal key..."
    kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if kubectl get secret -n openbao openbao-seal-key >/dev/null 2>&1; then
        echo "   ✅ openbao-seal-key already present — leaving it alone (replacing it would seal the vault for good)."
    else
        # Windows openssl ends its output with CRLF; `$(...)` strips the LF
        # only, and a key carrying a trailing CR is not valid base64, so the
        # static seal would fail to decode it the day the cluster graduates.
        # Found on a Docker Desktop homelab whose key was minted this way.
        kubectl create secret generic openbao-seal-key -n openbao \
            --from-literal=key="$(openssl rand -base64 32 | tr -d '\r\n')" >/dev/null
        echo "   ✅ openbao-seal-key created. Back it up off-cluster if this homelab holds anything you would miss."
    fi
fi

# --- Step 3: Install ArgoCD (Layer 3) ---
echo "🔥 [Layer 3] Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd --namespace argo "${HELM_APPLY_FLAGS[@]}" \
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

# Apply the Root App. Applied from a patched COPY, never straight from the
# source tree: the committed manifest carries the durable (Forgejo) repoURL
# form once the Phase 3 URL train lands, and a bootstrap-maturity cluster has
# no Forgejo to point at. Same rewrite the hydrated repos get.
echo "🌱 [Layer 4] Applying Root Application..."
ROOT_APP_DIR="$(mktemp -d)"
TEMP_DIRS+=("$ROOT_APP_DIR")
cp "$SCRIPT_DIR/platform/root-app.yaml" "$ROOT_APP_DIR/root-app.yaml"
patch_repo_urls_file "$ROOT_APP_DIR/root-app.yaml" "${HYDRATE_URL_MODE:-seed}" platform/root-app.yaml >/dev/null || exit 1
kubectl apply -f "$ROOT_APP_DIR/root-app.yaml" -n argo

echo "✅ Root Application applied. ArgoCD is now syncing from the internal Seed Gitea."

# Owning realm (optional): register a generic root-app pointing ArgoCD at the
# hydrated realm repo. Templated from the realm arg so nordri commits no
# realm-specific value. The realm's resources retry until the platform CRDs
# (Keycloak operator, ESO) they depend on exist.
if [[ -n "$REALM" ]]; then
    echo "🔗 [Layer 4] Registering realm root-app for '$REALM'..."
    # Same patched-copy rule as the root app above: the template's repoURL is
    # committed in the durable form and must be rewritten for the seed.
    sed "s|__REALM_REPO__|$REALM|g" "$SCRIPT_DIR/platform/argocd/realm-root-app.template.yaml" \
        > "$ROOT_APP_DIR/realm-root-app.yaml"
    patch_repo_urls_file "$ROOT_APP_DIR/realm-root-app.yaml" "${HYDRATE_URL_MODE:-seed}" platform/argocd/realm-root-app.template.yaml >/dev/null || exit 1
    kubectl apply -n argo -f "$ROOT_APP_DIR/realm-root-app.yaml"
fi

# --- GKE: Velero readiness check ---
# No credentials Secret is created here any more. GKE Velero authenticates via
# Workload Identity (`credentials.useSecret: false`), so the placeholder Secret
# that used to live here — created solely to stop a CrashLoopBackOff while the
# real config was a TODO — is gone. If an old one is still on the cluster from a
# previous bootstrap, remove it: it is inert but misleading.
#
# The GCS bucket and IAM bindings are a one-time, cluster-independent setup:
#   ./gke-provision.sh velero-setup
# Run it before or after bootstrap; Velero reports its BackupStorageLocation
# Unavailable until it exists.
if [[ "$TARGET" == "gke" ]]; then
    if kubectl get secret velero-credentials -n velero >/dev/null 2>&1; then
        echo "⚠️  A leftover 'velero-credentials' Secret exists in namespace velero."
        echo "   Workload Identity does not use it. Remove it to avoid confusion:"
        echo "     kubectl delete secret velero-credentials -n velero"
    fi
    echo "ℹ️  [GKE] Velero uses Workload Identity — no credentials Secret needed."
    echo "   One-time GCS + IAM setup (idempotent): ./gke-provision.sh velero-setup"
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
                # Garage 2.x prints "(redacted)" for the secret unless asked;
                # without --show-secret a re-run parsed that literal and
                # rewrote the Velero Secret with it.
                KEY_OUTPUT=$(kubectl exec -n garage garage-0 -- /garage key info --show-secret velero-service-key 2>/dev/null) || {
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

            # OpenBao snapshot agent (realm go-live design, 2026-09-16): its
            # own key and bucket beside Velero's, so a mistake in one backup
            # target cannot reach the other. The Secret's key names are the
            # openbao-helm chart's contract (s3CredentialsSecret). Created
            # only if absent: the key is stable, and a rotation is an explicit
            # delete-and-re-run, not a side effect of every bootstrap.
            #
            # The key's secret half moves Garage → 0600 file → Secret without
            # passing through a variable or an argument (lib/openbao.sh's
            # rule); only the key ID, which is not secret, is held in a
            # variable. The Velero block above predates this and still uses
            # --from-literal; bringing it to the same shape is a follow-up.
            echo "   Creating Garage API key for the OpenBao snapshot agent..."
            OB_SCRATCH=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/openbao-garage-XXXXXX")
            if ! ( umask 077; kubectl exec -n garage garage-0 -- /garage key create openbao-backup-key > "$OB_SCRATCH/key.txt" 2>/dev/null ); then
                ( umask 077; kubectl exec -n garage garage-0 -- /garage key info --show-secret openbao-backup-key > "$OB_SCRATCH/key.txt" 2>/dev/null ) || : > "$OB_SCRATCH/key.txt"
            fi
            OB_KEY_ID=$(grep -i "Key ID" "$OB_SCRATCH/key.txt" | awk '{print $NF}')
            ( umask 077; grep -i "Secret" "$OB_SCRATCH/key.txt" | awk '{print $NF}' | tr -d '\r\n' > "$OB_SCRATCH/secret" )
            if [[ -z "$OB_KEY_ID" || ! -s "$OB_SCRATCH/secret" ]] || grep -q '(redacted)' "$OB_SCRATCH/secret"; then
                rm -rf "$OB_SCRATCH"
                echo "⚠️  Could not create or read Garage key openbao-backup-key. Skipping OpenBao snapshot storage; re-run bootstrap to retry."
            else
                # A failed create is only acceptable when the bucket is already
                # there; the grant must succeed. Reporting "ready" over either
                # failure would park credentials for a target the agent cannot
                # write, and the first sign would be a stale-backup alert.
                if ! kubectl exec -n garage garage-0 -- /garage bucket create openbao-backups >/dev/null 2>&1 \
                   && ! kubectl exec -n garage garage-0 -- /garage bucket info openbao-backups >/dev/null 2>&1; then
                    echo "❌ Garage bucket openbao-backups could not be created and does not exist." >&2
                    exit 1
                fi
                if ! kubectl exec -n garage garage-0 -- /garage bucket allow openbao-backups --read --write --key openbao-backup-key >/dev/null 2>&1; then
                    echo "❌ Could not grant openbao-backup-key read/write on Garage bucket openbao-backups." >&2
                    exit 1
                fi
                echo "✅ Garage bucket 'openbao-backups' ready."
                if kubectl get secret -n openbao openbao-backup-s3 >/dev/null 2>&1; then
                    # The Secret is kept, so it must be THIS key: a Secret from
                    # an earlier key (Garage state wiped, Secret kept) would leave
                    # the agent uploading with credentials Garage no longer knows.
                    OB_SECRET_KEY_ID=$(kubectl get secret -n openbao openbao-backup-s3 -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode | tr -d '\r\n')
                    if [[ "$OB_SECRET_KEY_ID" != "$OB_KEY_ID" ]]; then
                        echo "❌ Secret openbao/openbao-backup-s3 holds access key '$OB_SECRET_KEY_ID' but Garage's openbao-backup-key is '$OB_KEY_ID'." >&2
                        echo "   To rotate onto the current key: kubectl delete secret openbao-backup-s3 -n openbao, then re-run this script." >&2
                        exit 1
                    fi
                    echo "   Secret openbao/openbao-backup-s3 already exists and matches the Garage key — keeping it."
                else
                    kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f -
                    printf '%s' "$OB_KEY_ID" > "$OB_SCRATCH/id"
                    kubectl create secret generic openbao-backup-s3 -n openbao \
                      --from-file=AWS_ACCESS_KEY_ID="$OB_SCRATCH/id" \
                      --from-file=AWS_SECRET_ACCESS_KEY="$OB_SCRATCH/secret"
                    echo "✅ OpenBao snapshot credentials secret created."
                fi
                if ! rm -rf "$OB_SCRATCH" || [[ -e "$OB_SCRATCH" ]]; then
                    echo "❌ Could not remove $OB_SCRATCH — it holds the Garage key; remove it by hand." >&2
                    exit 1
                fi
            fi
            break
        fi

        echo "   ... waiting for Garage pod ($ELAPSED/${TIMEOUT}s)"
        sleep 15
    done
else
    echo "ℹ️  Skipping Garage init (not homelab target)."
fi

# --- Step 5b: OpenBao init, configure, seed (Layer 5b) ---
# Everything between "OpenBao pod Running" and "the stack can read secrets"
# used to be hands: init, unseal, the KV/auth/policy setup ESO depends on, and
# the realm's seed values. A fresh homelab came up green on every layer and
# still could not import its Keycloak realm for want of those three steps.
# lib/openbao.sh does them idempotently; a re-run of this script changes
# nothing on a cluster that already has them.
#
# The init half runs on homelab, whose in-cluster custody realm ADR 0002
# accepts, and on gke only when OPENBAO_AUTO_INIT=1 says so deliberately. The
# configure and seed halves run wherever the instance is already unsealed.
echo "🔐 [Layer 5b] OpenBao init, configure, seed..."
if openbao_wait_running 600; then
    OPENBAO_READY_FOR_CONFIG=false
    if [[ "$TARGET" == "homelab" || "${OPENBAO_AUTO_INIT:-0}" == "1" ]]; then
        # An `a && b && flag=true` list would swallow a failure under set -e
        # and let bootstrap finish green with a vault that is not usable.
        if openbao_ensure_initialized && openbao_ensure_unsealed; then
            OPENBAO_READY_FOR_CONFIG=true
        else
            echo "❌ OpenBao initialization or unsealing failed — see the messages above; if an init file path was printed, park it before anything else." >&2
            exit 1
        fi
    elif [[ "$(openbao_status_field '.initialized' 2>/dev/null)" == "true" && "$(openbao_status_field '.sealed' 2>/dev/null)" == "false" ]]; then
        # Initialized by hand (the gke default). Configure and seed still need
        # the root token, which only the parked Secret provides — so require it
        # rather than fail deeper in with a less helpful error.
        if kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null 2>&1; then
            OPENBAO_READY_FOR_CONFIG=true
        else
            echo "ℹ️  OpenBao on $TARGET is initialized and unsealed but Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET is absent, so Layer 5b cannot authenticate to configure or seed."
            echo "   Park the init material as the runbook describes (nidavellir docs/secrets-management.md, 'Fresh cluster — full init': init.json plus a root_token key), then re-run this script."
        fi
    else
        echo "ℹ️  OpenBao on $TARGET is not initialized+unsealed and OPENBAO_AUTO_INIT is not set — init it by hand (shares to the password manager first), park the material in Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET, then re-run to configure and seed."
    fi
    if [[ "$OPENBAO_READY_FOR_CONFIG" == "true" ]]; then
        openbao_configure || { echo "❌ OpenBao configuration failed." >&2; exit 1; }
        OPENBAO_SEEDS_FILE="${OPENBAO_SEEDS_FILE:-}"
        if [[ -z "$OPENBAO_SEEDS_FILE" && -n "$REALM" && -f "$REALM_DIR/openbao-seeds" ]]; then
            OPENBAO_SEEDS_FILE="$REALM_DIR/openbao-seeds"
        fi
        if [[ -n "$OPENBAO_SEEDS_FILE" ]]; then
            echo "🌱 Seeding realm-declared OpenBao paths from $OPENBAO_SEEDS_FILE..."
            openbao_seed_file "$OPENBAO_SEEDS_FILE" || { echo "❌ OpenBao seeding failed." >&2; exit 1; }
        else
            echo "ℹ️  No openbao-seeds file for this realm — nothing to seed."
        fi
        echo "✅ OpenBao ready: ESO can read secret/*, realm seeds present."
    fi
else
    echo "⚠️  OpenBao never reached Running; skipping Layer 5b. Re-run this script once ArgoCD has deployed it (idempotent)."
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
