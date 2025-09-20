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

## Component Versions

- **K3s**: v1.31.5+k3s1
- **Percona Operator**: 2.7.0
- **Crossplane**: 2.0.2
- **Velero**: 1.17.0
- **Argo CD**: Latest stable (via Helm)

## Verification Commands

```bash
# Check all components are running
kubectl get pods -n percona-system
kubectl get pods -n crossplane-system
kubectl get pods -n argocd

# Check Helm releases
helm list -A

# Verify cluster status
kubectl get nodes
kubectl cluster-info
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
