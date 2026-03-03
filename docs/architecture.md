# Hybrid Multi-Cluster Architecture

## Project Overview

This document outlines the architecture for a robust, hybrid, multi-cluster Kubernetes environment that separates live production workloads from disaster recovery and personal workloads. The architecture leverages centralized object storage for cross-cluster backup and restore capabilities.

## High-Level Architecture

### Core Components

1. **GKE Cluster (Live/Production)**: Primary production environment
2. **Home Lab Cluster A (Standby/DR)**: Passive disaster recovery cluster
3. **Home Lab Cluster B (Personal)**: Independent personal workloads cluster
4. **Centralized Backup Storage**: Cloud-based object storage for all backups

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              HYBRID MULTI-CLUSTER ARCHITECTURE                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐  │
│  │   GKE CLUSTER       │    │  HOME LAB CLUSTER A │    │  HOME LAB CLUSTER B │  │
│  │   (Live/Production) │    │   (Standby/DR)      │    │   (Personal)        │  │
│  │                     │    │                     │    │                     │  │
│  │ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │  │
│  │ │  Core Platform  │ │    │ │  Core Platform  │ │    │ │  Core Platform  │ │  │
│  │ │  - Argo CD      │ │    │ │  - Argo CD      │ │    │ │  - Argo CD      │ │  │
│  │ │  - Mimir (Data) │ │    │ │  - Mimir (Data) │ │    │ │  - Mimir (Data) │ │  │
│  │ │  - Crossplane   │ │    │ │  - Crossplane   │ │    │ │  - Crossplane   │ │  │
│  │ │  - Velero       │ │    │ │  - Velero       │ │    │ │  - Velero       │ │  │
│  │ └─────────────────┘ │    │ └─────────────────┘ │    │ └─────────────────┘ │  │
│  │                     │    │                     │    │                     │  │
│  │ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │  │
│  │ │  Hobby/Community│ │    │ │   Standby Mode  │ │    │ │   Home Services │ │  │
│  │ │  - Xenforo      │ │    │ │   (Passive)     │ │    │ │   - Plex        │ │  │
│  │ │  - Sonarqube    │ │    │ │                 │ │    │ │   - Photo Sync  │ │  │
│  │ │  - Game Servers │ │    │ │                 │ │    │ │   - Home Cameras│ │  │
│  │ │  - Chatbot      │ │    │ │                 │ │    │ │   - Automation  │ │  │
│  │ └─────────────────┘ │    │ └─────────────────┘ │    │ └─────────────────┘ │  │
│  └─────────────────────┘    └─────────────────────┘    └─────────────────────┘  │
│           │                           │                           │             │
│           │                           │                           │             │
│           └───────────────────────────┼───────────────────────────┘             │
│                                       │                                         │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                    CENTRALIZED BACKUP STORAGE                              │ │
│  │                    (GCS/S3 Object Storage)                                 │ │
│  │                                                                            │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │ │
│  │  │GKE Backups  │  │Cluster A    │  │Cluster B    │  │Cross-Cluster│        │ │
│  │  │(Primary)    │  │Restore      │  │Backups      │  │Restore      │        │ │
│  │  │             │  │Data         │  │(Personal)   │  │Capability   │        │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

### Core Platform Components (All Clusters)

| Component | Purpose | Version | Notes |
|-----------|---------|---------|-------|
| **Kubernetes** | Container orchestration | v1.31+ | K3s for home lab, GKE for production |
| **Argo CD** | GitOps continuous deployment | Latest stable | Application lifecycle management |
| **Mimir** | Database Management Platform | - | Manages Percona, Kafka, Valkey (External Project) |
| **Crossplane** | Infrastructure as Code | 2.0+ | Self-service infrastructure provisioning |
| **Velero** | Backup and disaster recovery | 1.17.0+ | Cross-cluster backup/restore |
| **Heimdall** | Observability (Prometheus, Grafana, Loki, Tempo) | Latest | Metrics, logs, traces, dashboards |
| **Keycloak** | Identity and access management | Latest | Single sign-on and user management |
| **Backstage** | Developer portal | Latest | Service catalog and developer experience |

### Production-Specific Applications (GKE Cluster)

| Application | Purpose | Category |
|-------------|---------|----------|
| **Xenforo** | Community forum platform | Community |
| **Sonarqube** | Code quality analysis | Development |
| **Agones** | Game server orchestration | Gaming |
| **Jenkins** | CI/CD pipeline automation | Development |
| **Artifactory/Nexus** | Artifact repository | Development |
| **Chatbot Services** | Community interaction | Community |
| **Game Microservices** | Meta server, identity server | Gaming |

### Home Lab Applications (Cluster B)

| Application | Purpose | Category |
|-------------|---------|----------|
| **Plex** | Media server | Media |
| **Photo Sync** | Photo storage and sync | Storage |
| **Document Storage** | Document management | Storage |
| **Garage** | S3-compatible storage | Storage |
| **Longhorn** | Distributed storage | Storage |
| **Home Cameras** | Security monitoring | IoT |
| **Home Automation** | Smart home control | IoT |

## Cluster Configurations

### GKE Cluster (Live/Production)

**Purpose**: Primary production environment for community-facing services

### Home Lab Cluster A (Standby/DR)

**Purpose**: Passive disaster recovery cluster for the live GKE cluster

### Home Lab Cluster B (Personal)

**Purpose**: Personal and household services

## Backup and Disaster Recovery

**Storage Provider**: Google Cloud Storage (GCS)
**Access Pattern**: All clusters read/write backups to same bucket with path separation
**Security**: IAM-based access control with cluster-specific credentials

Need to find good ways to test and do regular exercises.
