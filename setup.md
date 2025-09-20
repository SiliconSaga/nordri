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

### 1.5 Install Argo CD (Optional but Recommended)
```bash
# Add Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm

# Update repositories
helm repo update

# Create namespace
kubectl create namespace argocd

# Install Argo CD
helm install argocd argo/argo-cd --namespace argocd

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### 1.6 Install Gitea (For GitOps Testing)
```bash
# Add Gitea Helm repository
helm repo add gitea-charts https://dl.gitea.io/charts/

# Update repositories
helm repo update

# Create namespace
kubectl create namespace gitea

# Install Gitea
helm install gitea gitea-charts/gitea --namespace gitea

# Port forward to access Gitea UI
kubectl port-forward svc/gitea-http -n gitea 3000:3000
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
# Manually create .env with your actual values

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

### 4. Velero CLI Verification
```bash
# Check Velero CLI version
velero version

# Expected output: Client version v1.17.0 (server error is expected until server is installed)

# Test Velero help
velero --help
```

### 5. Argo CD Verification
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

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Test Argo CD UI access
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 3
curl -k -s -o /dev/null -w "%{http_code}" https://localhost:8080

# Expected output: 200

# Access Argo CD UI
echo "Argo CD UI: https://localhost:8080"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
```

### 6. Gitea Verification
```bash
# Check Gitea and dependencies are running
kubectl get pods -n gitea

# Expected output: Multiple pods including:
# - gitea-* (main Gitea pod)
# - gitea-postgresql-ha-* (PostgreSQL for Gitea)
# - gitea-valkey-cluster-* (Redis for Gitea)

# Test Gitea UI access
kubectl port-forward svc/gitea-http -n gitea 3000:3000 &
sleep 5
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000

# Expected output: 200

# Access Gitea UI
echo "Gitea UI: http://localhost:3000"
echo "First-time setup will be required"
```

### 7. Helm Releases Verification
```bash
# Check all Helm releases
helm list -A

# Expected output: 5 releases:
# - percona-operator in percona-system
# - crossplane in crossplane-system  
# - argocd in argocd
# - gitea in gitea
```

### 8. Complete System Health Check
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
echo "First-time setup required"

echo -e "\n=== Environment Variables ==="
echo "Source .env file: source .env"
echo "Available variables: ARGOCD_ADMIN_PASSWORD, ARGOCD_SERVER_URL, etc."
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

## Next Steps

After successful installation of all components:

1. Configure Crossplane providers (provider-kubernetes, provider-helm)
2. Create XPostgreSQL CompositeResourceDefinition
3. Create Composition for Percona PostgreSQL
4. Set up Velero backup storage (MinIO or S3)
5. Configure Argo CD for GitOps workflow
6. Test end-to-end database provisioning and backup

## Notes

- All components are installed in their respective namespaces
- K3s cluster includes 2 agent nodes for better resource distribution
- Load balancer ports are configured for external access
- Velero CLI is installed but server component needs to be configured with backup storage
