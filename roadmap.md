# Crossplane-Percona-Velero Experiment Roadmap

## Project Overview

**Goal**: Perform a quick, end-to-end experiment to validate a GitOps-driven, self-service infrastructure model on a local K3s cluster.

**Desired Outcome**: A functioning PostgreSQL database provisioned by Crossplane and Percona (via Mimir), with a successful backup taken by Velero stored in MinIO (which needs to be Garage soon instead)

**Infrastructure**: Local K3s cluster managed by k3d with Gitea for GitOps testing

**Current Status**: Phase 1 Complete ✅ - All tools installed and tested

## Phase 1: Tool Installation

### 1.1 Create K3s Cluster
- [x] Create local K3s cluster using k3d
- [x] Verify cluster is accessible via `kubectl`
- [x] Confirm cluster is ready for component installation


### 1.3 Install Crossplane
- [x] Use Helm to install Crossplane (v2.0 or newer)
- [x] Deploy to `crossplane-system` namespace
- [x] Verify Crossplane pods are running
- [x] Confirm Crossplane is ready to accept providers

### 1.4 Install Velero
- [x] Install Velero CLI
- [x] Deploy MinIO (S3-compatible storage) using official Docker image
- [x] Configure Velero to use MinIO backend
- [x] Set up backup storage location (velero-backups bucket)
- [x] Verify Velero installation and connectivity

### 1.5 Install Argo CD (Optional but Recommended)
- [x] Use Helm to install Argo CD
- [x] Configure Argo CD for GitOps workflow simulation
- [x] Set up initial Argo CD configuration
- [x] Verify Argo CD UI is accessible

### 1.6 Install Gitea (For GitOps Testing)
- [x] Use Helm to install Gitea
- [x] Deploy to `gitea` namespace
- [x] Configure Gitea with SQLite (bootstrap setup)
- [x] Verify Gitea UI is accessible
- [x] Set up repository for GitOps testing

## Phase 2: Platform Configuration

### 2.1 Configure Crossplane Providers
- [x] Install `provider-kubernetes` for Crossplane
- [x] Install `provider-helm` for Crossplane
- [ ] Verify providers are installed and healthy
- [ ] Test provider connectivity

### 2.2 Define Platform Abstraction Layer
- [ ] Create generic Composition for Gitea (future)
- [ ] Create generic Composition for other platform tools
- [ ] Verify Compositions are accepted by Crossplane

## Phase 3: Platform End-to-End Test

### 3.1 Gitea Integration
- [x] Install Gitea
- [x] Configure for GitOps
- [ ] Automate repository creation via Crossplane (future)

### 3.2 GitOps Workflow
- [ ] Configure Argo CD to monitor Gitea test application repository
- [ ] Set up Argo CD application for automatic deployment
- [ ] Verify automatic synchronization

## Success Criteria

- [ ] Crossplane providers successfully installed
- [ ] Platform components (ArgoCD, Gitea, Velero) functioning
- [ ] GitOps workflow is fully automated
- [ ] Velero backup captures platform state

## Prerequisites

- [x] k3d installed and ready
- [x] Local K3s cluster (created)
- [x] Git repository for source of truth (Gitea instance)
- [x] Helm installed
- [x] kubectl configured for cluster access

## Notes

- This experiment validates the self-service infrastructure model
- Focus on end-to-end workflow rather than production hardening
- Document any issues or deviations from the plan
- Keep track of timing for each phase
- Note any configuration challenges or solutions

### Gitea Configuration Decision
- **Current Setup**: Gitea with SQLite database (bootstrap configuration)
- **Rationale**: Simplified setup for initial testing, avoids PostgreSQL dependency issues
- **Future Upgrade Path**: Once Mimir database platform is proven, consider upgrading Gitea to use PostgreSQL:
  - Option 1: Upgrade existing Gitea instance to use PostgreSQL
  - Option 2: Deploy new "production" Gitea instance with PostgreSQL
  - Option 3: Use Crossplane to provision PostgreSQL for Gitea (meta-experiment)

## Troubleshooting

- Monitor pod logs for any component failures
- Check resource quotas and limits
- Verify network connectivity between components
- Ensure proper RBAC permissions are set
- Check Velero backup storage accessibility
