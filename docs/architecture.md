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
│                              HYBRID MULTI-CLUSTER ARCHITECTURE                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐  │
│  │   GKE CLUSTER       │    │  HOME LAB CLUSTER A │    │  HOME LAB CLUSTER B │  │
│  │   (Live/Production) │    │   (Standby/DR)      │    │   (Personal)        │  │
│  │                     │    │                     │    │                     │  │
│  │ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │  │
│  │ │   Core Platform │ │    │ │   Core Platform │ │    │ │   Core Platform │ │  │
│  │ │   - Argo CD     │ │    │ │   - Argo CD     │ │    │ │   - Argo CD     │ │  │
│  │ │   - Mimir (Data)│ │    │ │   - Mimir (Data)│ │    │ │   - Mimir (Data)│ │  │
│  │ │   - Crossplane  │ │    │ │   - Crossplane  │ │    │ │   - Crossplane  │ │  │
│  │ │   - Velero      │ │    │ │   - Velero      │ │    │ │   - Velero      │ │  │
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
| **Prometheus/Grafana** | Monitoring and observability | Latest | Metrics collection and visualization |
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
| **MinIO** | S3-compatible storage | Storage |
| **Home Cameras** | Security monitoring | IoT |
| **Home Automation** | Smart home control | IoT |
| **Longhorn** | Distributed storage | Storage |

## Cluster Configurations

### GKE Cluster (Live/Production)

**Purpose**: Primary production environment for community-facing services

**Configuration**:
- **Provider**: Google Kubernetes Engine
- **Node Pool**: Multi-zone, auto-scaling
- **Storage**: Persistent disks with snapshots
- **Networking**: VPC-native with Cloud Load Balancing
- **Security**: Workload Identity, Pod Security Standards

**Backup Strategy**:
- **Frequency**: Daily automated backups
- **Retention**: 30 days for daily, 12 months for weekly
- **Scope**: Full cluster state (manifests + persistent volumes)
- **Database Backups**: Managed via Mimir + Velero snapshots

### Home Lab Cluster A (Standby/DR)

**Purpose**: Passive disaster recovery cluster

**Configuration**:
- **Provider**: K3s on bare metal/virtualization
- **Resources**: Sufficient to run production workloads
- **Storage**: Local storage with backup to centralized storage
- **Networking**: VPN connection to production environment

**Operational Mode**:
- **State**: Passive standby (no active workloads)
- **Sync**: Regular restore from production backups
- **Activation**: Manual failover process
- **Validation**: Monthly DR testing

### Home Lab Cluster B (Personal)

**Purpose**: Personal and household services

**Configuration**:
- **Provider**: K3s on home lab hardware
- **Resources**: Scaled for personal use
- **Storage**: Longhorn distributed storage
- **Networking**: Home network with external access

**Backup Strategy**:
- **Frequency**: Weekly automated backups
- **Retention**: 12 weeks for weekly, 12 months for monthly
- **Scope**: Personal workloads and data
- **Cross-Restore**: Can restore to production cluster if needed

## Backup and Disaster Recovery

### Centralized Storage Architecture

**Storage Provider**: Google Cloud Storage (GCS) or AWS S3
**Access Pattern**: All clusters read/write to same bucket with path separation
**Security**: IAM-based access control with cluster-specific credentials

## Network Architecture

### Production Environment (GKE)
- **Ingress**: Google Cloud Load Balancer with SSL termination
- **Internal**: VPC-native networking with service mesh (Istio)
- **External**: Public IPs for game servers and community services
- **Security**: Cloud Armor for DDoS protection

### Home Lab Environment
- **Ingress**: Traefik load balancer with Let's Encrypt SSL
- **Internal**: K3s default networking with optional service mesh
- **External**: Dynamic DNS with port forwarding or VPN
- **Security**: Firewall rules and network segmentation

### Cross-Cluster Communication
- **Backup Sync**: Secure API calls to centralized storage
- **Monitoring**: Cross-cluster metrics aggregation
- **Management**: Centralized configuration management

## Security Considerations

### Access Control
- **Production**: Google Cloud IAM with Workload Identity
- **Home Lab**: RBAC with local user management
- **Cross-Cluster**: Shared secrets management (External Secrets Operator)

### Data Protection
- **Encryption at Rest**: All persistent volumes encrypted
- **Encryption in Transit**: TLS for all inter-service communication
- **Backup Encryption**: Client-side encryption for backup data
- **Key Management**: Cloud KMS for production, local key management for home lab

### Network Security
- **Production**: VPC with private clusters, authorized networks
- **Home Lab**: VPN access, firewall rules, network segmentation
- **Cross-Cluster**: Secure backup storage access only

## Monitoring and Observability

### Production Monitoring
- **Metrics**: Prometheus with long-term storage (Thanos)
- **Logging**: Centralized logging with log aggregation
- **Alerting**: PagerDuty integration for critical alerts
- **Dashboards**: Grafana with production-specific dashboards

### Home Lab Monitoring
- **Metrics**: Local Prometheus with basic retention
- **Logging**: Local log aggregation
- **Alerting**: Email/Slack notifications
- **Dashboards**: Grafana with home lab dashboards

### Cross-Cluster Monitoring
- **Backup Status**: Centralized backup monitoring
- **Health Checks**: Cross-cluster service health validation
- **Capacity Planning**: Resource utilization across clusters

## Implementation Phases

### Phase 1: Foundation Setup
- [ ] Deploy GKE production cluster
- [ ] Install core platform components
- [ ] Configure centralized backup storage
- [ ] Set up monitoring and alerting

### Phase 2: Home Lab Setup
- [ ] Deploy K3s clusters (A and B)
- [ ] Install core platform components
- [ ] Configure backup and restore capabilities
- [ ] Test cross-cluster backup/restore

### Phase 3: Application Deployment
- [ ] Deploy production applications (GKE)
- [ ] Deploy personal applications (Home Lab B)
- [ ] Configure standby cluster (Home Lab A)
- [ ] Validate end-to-end workflows

### Phase 4: Disaster Recovery Testing
- [ ] Test production failure scenarios
- [ ] Validate standby cluster activation
- [ ] Test personal workload recovery
- [ ] Document recovery procedures

See roadmap.md for more details

## Operational Considerations

### Maintenance Windows
- **Production**: Scheduled maintenance with community notification
- **Home Lab**: Flexible maintenance during off-hours
- **Cross-Cluster**: Coordinated backup maintenance

### Capacity Planning
- **Production**: Auto-scaling with resource monitoring
- **Home Lab**: Manual scaling based on usage patterns
- **Storage**: Growth planning for centralized backup storage

### Cost Optimization
- **Production**: Right-sizing with monitoring and optimization
- **Home Lab**: Resource efficiency for personal use
- **Storage**: Lifecycle policies for backup retention

## Future Enhancements

### Potential Improvements
- **Multi-Region**: Geographic distribution for disaster recovery
- **Edge Computing**: Local edge clusters for reduced latency
- **AI/ML Integration**: Intelligent backup scheduling and failure prediction
- **Service Mesh**: Advanced traffic management and security

### Scalability Considerations
- **Horizontal Scaling**: Additional clusters for specific workloads
- **Vertical Scaling**: Resource optimization and performance tuning
- **Storage Scaling**: Distributed storage solutions for large datasets

## Conclusion

This hybrid multi-cluster architecture provides a robust foundation for separating production and personal workloads while maintaining disaster recovery capabilities. The centralized backup strategy ensures data protection and enables flexible recovery scenarios across all environments.

The architecture balances operational complexity with reliability, providing a scalable platform for both community services and personal use cases while maintaining the ability to recover from various failure scenarios.
