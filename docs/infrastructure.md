# Infrastructure & Platform Components

This document details the core infrastructure components installed in the cluster, their configuration, and management.

## Crossplane

Crossplane is used as the abstraction layer for provisioning databases and other "primitives"

Percona has been split out into its own "Mimir" project which also includes Kafka and Valkey - overall data management.

*   **Namespace**: `crossplane-system`
*   **RBAC**: Updated in `refr-k8s/crossplane-rbac.yaml` to allow management of namespaces.

## Ingress (Traefik) (K3s Default)

*   **Type**: LoadBalancer (via K3s/k3d network)
*   **Dashboard**: Not exposed by default on k3s, managed via CRDs.

## GitOps (ArgoCD)

*   **Namespace**: `argocd`
*   **Access**: Port-forwarded to localhost:8080 usually.
