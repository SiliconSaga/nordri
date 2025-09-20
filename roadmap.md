# Crossplane-Percona-Velero Experiment Roadmap

## Project Overview

**Goal**: Perform a quick, end-to-end experiment to validate a GitOps-driven, self-service infrastructure model on a local K3s cluster.

**Desired Outcome**: A functioning PostgreSQL database provisioned by Crossplane and Percona, with a successful backup taken by Velero.

**Infrastructure**: Local K3s cluster managed by k3d (cluster needs to be created)

## Phase 1: Tool Installation

### 1.1 Create K3s Cluster
- [ ] Create local K3s cluster using k3d
- [ ] Verify cluster is accessible via `kubectl`
- [ ] Confirm cluster is ready for component installation

### 1.2 Install Percona Operator
- [ ] Use Helm to install Percona Operator for PostgreSQL
- [ ] Deploy to `percona-system` namespace
- [ ] Verify operator pod is running
- [ ] Check operator logs for any issues

### 1.3 Install Crossplane
- [ ] Use Helm to install Crossplane (v2.0 or newer)
- [ ] Deploy to `crossplane-system` namespace
- [ ] Verify Crossplane pods are running
- [ ] Confirm Crossplane is ready to accept providers

### 1.4 Install Velero
- [ ] Install Velero CLI
- [ ] Configure Velero to point to local MinIO or S3-compatible service
- [ ] Set up backup storage location
- [ ] Verify Velero installation and connectivity

### 1.5 Install Argo CD (Optional but Recommended)
- [ ] Use Helm to install Argo CD
- [ ] Configure Argo CD for GitOps workflow simulation
- [ ] Set up initial Argo CD configuration
- [ ] Verify Argo CD UI is accessible

## Phase 2: Platform Configuration

### 2.1 Configure Crossplane Providers
- [ ] Install `provider-kubernetes` for Crossplane
- [ ] Install `provider-helm` for Crossplane
- [ ] Verify providers are installed and healthy
- [ ] Test provider connectivity

### 2.2 Define Abstraction Layer
- [ ] Create `XPostgreSQL.yaml` - CompositeResourceDefinition (XRD)
  - Define high-level XPostgreSQL resource
  - Include fields: `storageSize` and `version`
  - Set up proper schema validation
- [ ] Create `Composition.yaml` - Composition logic
  - Define how Crossplane translates XPostgreSQL to PerconaServerForPostgreSQL
  - Include Kubernetes Service creation
  - Include Secret generation for database credentials
  - Set up proper resource relationships

### 2.3 Apply Abstraction
- [ ] Commit `XPostgreSQL.yaml` to Git repository
- [ ] Commit `Composition.yaml` to Git repository
- [ ] Push changes to remote repository
- [ ] Apply XRD to cluster: `kubectl apply -f XPostgreSQL.yaml`
- [ ] Apply Composition to cluster: `kubectl apply -f Composition.yaml`
- [ ] Verify XRD and Composition are accepted by Crossplane

## Phase 3: End-to-End Test

### 3.1 Create Test Application
- [ ] Create new Git repository for test application
- [ ] Create application manifest with:
  - `kind: XPostgreSQL` resource definition
  - Simple Deployment that uses the database
  - Proper resource dependencies
- [ ] Commit and push test application to repository

### 3.2 Deploy with GitOps
- [ ] Configure Argo CD to monitor test application repository
- [ ] Set up Argo CD application for automatic deployment
- [ ] Watch Argo CD automatically provision the database
- [ ] Monitor deployment progress in Argo CD UI

### 3.3 Verify Database
- [ ] Use `kubectl get all` to confirm Percona operator created resources
- [ ] Verify primary and replica pods are running
- [ ] Check database logs for successful startup
- [ ] Extract credentials from generated secret
- [ ] Test database connectivity using credentials
- [ ] Verify database is accepting connections

### 3.4 Test Backup
- [ ] Use Velero CLI to trigger manual backup of test namespace
- [ ] Monitor backup progress
- [ ] Verify backup files appear in S3 storage
- [ ] Check backup metadata and completeness
- [ ] Validate backup contains all necessary resources

### 3.5 Test Restore
- [ ] Delete database pods to simulate failure
- [ ] Use Velero to restore from backup
- [ ] Monitor restore progress
- [ ] Verify database pods are recreated
- [ ] Confirm database is accessible after restore
- [ ] Test data integrity and connectivity
- [ ] Validate complete recovery

## Success Criteria

- [ ] XPostgreSQL resource can be created via GitOps
- [ ] Percona operator successfully provisions PostgreSQL
- [ ] Database is accessible and functional
- [ ] Velero backup captures all necessary resources
- [ ] Velero restore successfully recovers the database
- [ ] Data integrity is maintained through backup/restore cycle
- [ ] GitOps workflow is fully automated

## Prerequisites

- [x] k3d installed and ready
- [ ] Local K3s cluster (to be created)
- [ ] Git repository for source of truth
- [ ] Helm installed
- [ ] kubectl configured for cluster access

## Notes

- This experiment validates the self-service infrastructure model
- Focus on end-to-end workflow rather than production hardening
- Document any issues or deviations from the plan
- Keep track of timing for each phase
- Note any configuration challenges or solutions

## Troubleshooting

- Monitor pod logs for any component failures
- Check resource quotas and limits
- Verify network connectivity between components
- Ensure proper RBAC permissions are set
- Validate storage class availability for Percona
- Check Velero backup storage accessibility
