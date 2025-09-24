# Crossplane-Percona-Velero Experiment Setup

This document contains the working commands and versions used for the Crossplane-Percona-Velero experiment setup.

## Prerequisites

- k3d installed and ready
- Helm installed
- kubectl configured
- Homebrew (for Velero installation)

## Phase 1: Tool Installation Commands

### 1.1 Create K3s Cluster
```bash
# Create K3s cluster with load balancer ports
k3d cluster create refr-k8s --port "8080:80@loadbalancer" --port "8443:443@loadbalancer" --agents 2

# Merge kubeconfig
k3d kubeconfig merge refr-k8s --kubeconfig-merge-default

# Verify cluster
kubectl cluster-info
kubectl get nodes
```

### 1.2 Install Percona Operator
```bash
# Add Percona Helm repository
helm repo add percona https://percona.github.io/percona-helm-charts/

# Update repositories
helm repo update

# Create namespace
kubectl create namespace percona-system

# Install Percona Operator for PostgreSQL
helm install percona-operator percona/pg-operator --namespace percona-system

# Verify installation
kubectl get pods -l app.kubernetes.io/name=pg-operator --namespace percona-system
```

### 1.3 Install Crossplane
```bash
# Create namespace
kubectl create namespace crossplane-system

# Add Crossplane Helm repository
helm repo add crossplane-stable https://charts.crossplane.io/stable

# Update repositories
helm repo update

# Install Crossplane
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system

# Verify installation
kubectl get pods -n crossplane-system
```

### 1.4 Install Velero CLI
```bash
# Install Velero CLI using Homebrew (recommended method for Mac)
brew install velero

# Verify installation
velero version
```

**Note**: Velero version installed: v1.17.0 (latest as of setup date)

### 1.5 Install MinIO (S3-Compatible Storage)
```bash
# Create namespace for MinIO
kubectl create namespace minio

# Deploy MinIO using official Docker image
kubectl apply -f minio-deployment.yaml

# Verify MinIO deployment
kubectl get pods -n minio
kubectl get svc -n minio
```

**MinIO Configuration:**
- **Image**: `minio/minio:latest` (official image, avoiding Bitnami licensing issues)
- **Storage**: 20Gi using local-path storage class
- **Credentials**: Set via environment variables (`$MINIO_ACCESS_KEY` / `$MINIO_SECRET_KEY`)
- **API Endpoint**: `http://localhost:9000` (for Velero/S3 operations)
- **Web Console**: `http://localhost:9001` (for management)

**Port Forwarding (run in separate terminals):**
```bash
# Terminal 1: MinIO API (for Velero)
kubectl port-forward svc/minio -n minio 9000:9000

# Terminal 2: MinIO Console (for web management)
kubectl port-forward svc/minio-console -n minio 9001:9001
```

**Create Velero Backup Bucket:**
1. Open browser to `http://localhost:9001`
2. Login with your MinIO credentials (from .env file)
3. Click "Create Bucket"
4. Bucket name: `velero-backups`
5. Click "Create Bucket"

### 1.6 Install Velero Server (Hybrid MinIO + GCP)
```bash
# Create Velero credentials file for MinIO (using environment variables)
cat > credentials-velero << EOF
[default]
aws_access_key_id = $MINIO_ACCESS_KEY
aws_secret_access_key = $MINIO_SECRET_KEY
EOF

# Set proper permissions
chmod 600 credentials-velero

# Install Velero server with MinIO backend (AWS provider for S3-compatibility)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000

# Verify Velero installation
kubectl get pods -n velero
velero version
```

**Velero Configuration:**
- **Provider**: AWS (for S3-compatibility with MinIO - don't need to actually use AWS)
- **Backend**: MinIO (local S3-compatible storage)
- **Bucket**: `velero-backups`
- **Region**: `us-east-1` (default for S3-compatible)
- **Endpoint**: `http://localhost:9000` (MinIO API)

**Future GCP Integration:**
- MinIO will replicate to GCP bucket for long-term storage
- Cross-cluster restore capability via GCP
- Hybrid approach: Fast local + Cloud redundancy

### 1.7 Install Argo CD (Optional but Recommended)

First, create a values file for local development - see `argocd-values.yaml`

```bash
# Add Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm

# Update repositories
helm repo update

# Create namespace
kubectl create namespace argocd

# Install Argo CD with local development configuration
helm install argocd argo/argo-cd --namespace argocd -f argocd-values.yaml

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access Argo CD UI (insecure mode for local development)
kubectl port-forward svc/argocd-server -n argocd 8080:80

# Access Argo CD
# URL: http://localhost:8080 (HTTP for insecure mode)
# Username: admin
# Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
```

### 1.8 Install Gitea (For GitOps Testing)

First, create a values file for a clean SQLite-based installation - see `gitea-values.yaml`

```bash
# Add Gitea Helm repository
helm repo add gitea-charts https://dl.gitea.io/charts/

# Update repositories
helm repo update

# Create namespace
kubectl create namespace gitea

# Install Gitea with custom configuration
helm install gitea gitea-charts/gitea --namespace gitea -f gitea-values.yaml
```

## Gitea Setup and Access

### 1. Create Admin and Personal Users
```bash
# Create admin user
kubectl exec -n gitea deployment/gitea -- gitea admin user create \
  --username admin \
  --password $GITEA_ADMIN_PASSWORD \
  --email admin@localhost \
  --admin \
  --must-change-password=false

# Create personal user account  
kubectl exec -n gitea deployment/gitea -- gitea admin user create \
  --username Cervator \
  --password $GITEA_PERSONAL_PASSWORD \
  --email cervator@gmail.com \
  --must-change-password=false
```

### 2. Access Gitea Services
```bash
# Port forward for HTTP access (web UI)
kubectl port-forward svc/gitea-http -n gitea 3000:3000

# Port forward for SSH access (Git operations)
kubectl port-forward svc/gitea-ssh -n gitea 2222:2222

# Open web UI in browser
open http://localhost:3000
```

### 3. Login Credentials
- **Web UI**: http://localhost:3000
- **SSH**: localhost:2222
- Set / find usernames and passwords in .env

### 4. Test SSH Connection
```bash
# Test SSH connectivity (should show connection established)
ssh -T git@localhost -p 2222

# Expected: Connection established, then "Permission denied" (normal without SSH keys)
```

### 5. Create Test Repository
After logging in as `Cervator`, create a test repository:

1. Navigate to http://localhost:3000 and login with Cervator
2. Click the "+" button in the top navigation
3. Select "New Repository"
4. Fill in the details:
   - **Repository Name**: `refr-k8s-test`
   - **Description**: `Test repository for Crossplane-Percona-Velero experiment`
   - **Visibility**: Private (recommended for testing)
5. Click "Create Repository"

### 6. Configure Git Access
```bash
# Configure Git with your personal credentials (if not already done)
git config --global user.name "Cervator"
git config --global user.email "cervator@gmail.com"

# Add Gitea as a remote (after creating the repository)
git remote add gitea http://localhost:3000/Cervator/refr-k8s-test.git

# For SSH access, first add your SSH key to Gitea:
# 1. If needed then generate SSH key: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_gitea.pub
# 2. Copy public key: cat ~/.ssh/id_ed25519_gitea.pub
# 3. Add to Gitea: Settings → SSH/GPG Keys → Add Key
# 4. Then use SSH remote via CLI, Git Kraken, or other tool
```

### 7. Test Repository Access
```bash
# Test pushing to Gitea repository (HTTPS)
echo "# Test Repository for refr-k8s" > README.md
git add README.md
git commit -m "Initial commit"
git push gitea main

# Or test with SSH (after setting up SSH keys)
git push gitea-ssh main
```

## Component Versions

- **K3s**: v1.31.5+k3s1
- **Percona Operator**: 2.7.0
- **Crossplane**: 2.0.2
- **Velero**: 1.17.0
- **Argo CD**: Latest stable (via Helm)
- **Gitea**: Latest stable (via Helm)

## Environment Setup

### Create Environment File

Create a `.env` file manually with sensitive data (never commit this file):

```bash
# Create .env file with sensitive data
# DO NOT include actual secrets in documentation
# Example structure (use your actual values):

# MinIO Configuration
MINIO_ACCESS_KEY=your-minio-access-key
MINIO_SECRET_KEY=your-minio-secret-key

# Gitea Configuration  
GITEA_ADMIN_PASSWORD=your-admin-password
GITEA_PERSONAL_PASSWORD=your-personal-password
GITEA_URL=http://localhost:3000
GITEA_REPO_URL=http://localhost:3000/Cervator/refr-k8s-test.git

# Argo CD Configuration
ARGOCD_ADMIN_PASSWORD=your-argocd-password
ARGOCD_SERVER_URL=http://localhost:8080

# Source the environment variables
source .env
```

**Important**: The `.env` file contains sensitive information and should never be committed to version control. The `.gitignore` file already excludes `.env` files.


### Create .gitignore

Don't need to embed that here either, the file is right there! :-)

## Verification Commands

### 1. Cluster Verification
```bash
# Verify cluster is accessible
kubectl cluster-info
kubectl get nodes

# Expected output: 3 nodes (1 control-plane, 2 agents) all Ready
```

### 2. Percona Operator Verification
```bash
# Check operator pod is running
kubectl get pods -l app.kubernetes.io/name=pg-operator --namespace percona-system

# Expected output: 1/1 Running

# Check operator logs for successful startup
kubectl logs -l app.kubernetes.io/name=pg-operator --namespace percona-system --tail=10

# Expected output: Controller startup messages, no errors

# Verify operator can see CRDs
kubectl get crd | grep percona
```

### 3. Crossplane Verification
```bash
# Check Crossplane pods are running
kubectl get pods -n crossplane-system

# Expected output: 2 pods (crossplane and crossplane-rbac-manager) both 1/1 Running

# Verify Crossplane CRDs are installed
kubectl get crd | grep crossplane

# Expected output: Multiple Crossplane CRDs including:
# - compositeresourcedefinitions.apiextensions.crossplane.io
# - compositions.apiextensions.crossplane.io
# - providers.pkg.crossplane.io

# Check Crossplane logs
kubectl logs -n crossplane-system -l app=crossplane --tail=10
```

### 4. MinIO Verification
```bash
# Check MinIO pods are running
kubectl get pods -n minio

# Expected output: MinIO pod 1/1 Running

# Check MinIO services
kubectl get svc -n minio

# Expected output: Services with correct ports
# - minio: 9000/TCP (API)
# - minio-console: 9001/TCP (Web UI)

# Test MinIO API connectivity (after port-forward)
curl -I http://localhost:9000/minio/health/live

# Expected output: HTTP/1.1 200 OK

# Check MinIO logs
kubectl logs -n minio deployment/minio --tail=10
```

### 5. Velero Server Verification
```bash
# Check Velero pods are running
kubectl get pods -n velero

# Expected output: Velero pods 1/1 Running

# Check Velero CLI and server connectivity
velero version

# Expected output: Both client and server versions

# Test Velero backup location
velero backup-location get

# Expected output: MinIO backup location configured

# Test Velero help
velero --help
```

### 6. Argo CD Verification
```bash
# Check all Argo CD components are running
kubectl get pods -n argocd

# Expected output: 7 pods all 1/1 Running:
# - argocd-application-controller-0
# - argocd-applicationset-controller-*
# - argocd-dex-server-*
# - argocd-notifications-controller-*
# - argocd-redis-*
# - argocd-repo-server-*
# - argocd-server-*

# Check Argo CD services
kubectl get svc -n argocd

# Expected output: Services with correct ports
# - argocd-server: 80/TCP, 443/TCP

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Test Argo CD UI access (after port-forward is running)
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080

# Expected output: 200

# Access Argo CD UI
echo "Argo CD UI: http://localhost:8080 (HTTP for insecure mode)"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"

# Verify Argo CD CLI access (optional)
kubectl get applications -n argocd
```

### 7. Gitea Verification
```bash
# Check Gitea pods are running
kubectl get pods -n gitea

# Expected output: Gitea pod and Valkey cluster pods running
# - gitea-* (main Gitea pod) - 1/1 Running
# - gitea-valkey-cluster-* (Redis cache) - 1/1 Running

# Check services are properly configured
kubectl get svc -n gitea

# Expected output: Services with correct ports
# - gitea-http: 3000/TCP
# - gitea-ssh: 2222/TCP

# Test HTTP access
kubectl port-forward svc/gitea-http -n gitea 3000:3000 &
sleep 3
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000

# Expected output: 200

# Test SSH connectivity
kubectl port-forward svc/gitea-ssh -n gitea 2222:2222 &
sleep 3
ssh -T -p 2222 -o ConnectTimeout=5 git@localhost 2>&1 | head -1

# Expected output: Connection established (then permission denied is normal)

# Display access information
echo "=== Gitea Access Information ==="
echo "Web UI: http://localhost:3000"
echo "SSH: localhost:2222"
echo "Set / find credentials in .env"
```

### 8. Helm Releases Verification
```bash
# Check all Helm releases
helm list -A

# Expected output: 5 releases:
# - percona-operator in percona-system
# - crossplane in crossplane-system  
# - argocd in argocd
# - gitea in gitea
```

### 9. Complete System Health Check
```bash
# Run comprehensive health check
echo "=== Cluster Status ==="
kubectl get nodes

echo -e "\n=== All Pods Status ==="
kubectl get pods -A | grep -E "(percona|crossplane|argocd|gitea)"

echo -e "\n=== Helm Releases ==="
helm list -A

echo -e "\n=== Argo CD Access ==="
echo "UI: https://localhost:8080 (after port-forward)"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"

echo -e "\n=== Gitea Access ==="
echo "UI: http://localhost:3000 (after port-forward)"
echo "SSH: localhost:2222 (after port-forward)"
echo "Set / find credentials in .env"

echo -e "\n=== Environment Variables ==="
echo "Source .env file: source .env"
echo "Available variables: ARGOCD_ADMIN_PASSWORD, ARGOCD_SERVER_URL, GITEA_URL, etc."
```

## Troubleshooting

### Percona Operator Issues
```bash
# Check operator logs
kubectl logs -l app.kubernetes.io/name=pg-operator --namespace percona-system

# Describe pod for events
kubectl describe pod -l app.kubernetes.io/name=pg-operator --namespace percona-system
```

### Crossplane Issues
```bash
# Check Crossplane logs
kubectl logs -n crossplane-system -l app=crossplane

# Check RBAC manager logs
kubectl logs -n crossplane-system -l app=crossplane-rbac-manager
```

### Velero Issues
```bash
# Check Velero server status (after server installation)
kubectl get pods -n velero

# Check Velero logs
kubectl logs -n velero -l app.kubernetes.io/name=velero
```

## Velero Testing

### Prerequisites
- MinIO port-forward running: `kubectl port-forward svc/minio -n minio 9000:9000`
- Velero server installed and running

### Basic Backup/Restore Test
```bash
# Create a test backup
velero backup create test-backup --include-namespaces gitea

# Check backup status
velero backup get

# Test restore
velero restore create test-restore --from-backup test-backup

# Clean up
velero backup delete test-backup
velero restore delete test-restore
```

### Verify Backup Storage
```bash
# Check backup location status
velero backup-location get

# List all backups
velero backup get

# Check MinIO bucket contents (via web console at localhost:9001)
```

## Phase 2: Platform Configuration

### 2.1 Crossplane Providers ✅
```bash
# Install Crossplane providers
kubectl apply -f - << 'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.9.0
EOF

kubectl apply -f - << 'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v0.18.0
EOF

# Verify providers
kubectl get providers -n crossplane-system
```

### 2.2 XPostgreSQL CompositeResourceDefinition ✅
```bash
# Apply XPostgreSQL CRD (v2 API)
kubectl apply -f XPostgreSQL-v2.yaml

# Verify CRD
kubectl get crd xpostgresqls.database.example.org

# Test XPostgreSQL resource
kubectl apply -f test-postgresql.yaml
kubectl get xpostgresqls
```

### 2.3 Composition ✅
```bash
# Install go-templating function (required for pipeline mode)
kubectl apply -f - << 'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-go-templating
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-go-templating:v0.4.0
EOF

# Apply Composition (pipeline mode for v2)
kubectl apply -f Composition.yaml

# Verify Composition
kubectl get compositions
kubectl get functions
```

### 2.4 Test XPostgreSQL ✅
```bash
# Create test PostgreSQL instance
kubectl apply -f test-postgresql.yaml

# Check status
kubectl get xpostgresqls
kubectl describe xpostgresql test-postgresql

# Verify resources created
kubectl get namespaces | grep postgresql
```

**Note**: The PerconaServerForPostgreSQL CRD error is expected since we haven't installed the Percona Operator yet. The Crossplane setup is working correctly - it's creating namespaces and attempting to create the PostgreSQL resources as designed.

## Next Steps

After successful installation of all components:

1. ✅ Configure Crossplane providers (provider-kubernetes, provider-helm)
2. ✅ Create XPostgreSQL CompositeResourceDefinition
3. 🔄 Create Composition for Percona PostgreSQL (v2 pipeline mode)
4. Set up GCP replication for MinIO (long-term storage)
5. Configure Argo CD for GitOps workflow
6. Test end-to-end database provisioning and backup

## Notes

- All components are installed in their respective namespaces
- K3s cluster includes 2 agent nodes for better resource distribution
- Load balancer ports are configured for external access
- Velero CLI is installed but server component needs to be configured with backup storage
