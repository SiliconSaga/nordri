# Nordri Bootstrapping Strategy: "Layer 0.5"

This document details the bootstrapping process for Nordri clusters (GKE and Homelab). It solves the "Chicken and Egg" problem of GitOps (ArgoCD needing a repo to install itself) by introducing a **Layer 0.5: The Hydrated Seed**.

## The Core Concept: "Seed Gitea"

Instead of relying on a central GitHub repository that manages all clusters (which creates single-point-of-failure and complexity for disconnected homelabs), we inject a **Local Gitea Instance** into every new cluster as the *very first step*.

This Gitea acts as the independent "Brain" for that cluster.

### The Layers

1.  **Layer 0 (The Metal)**
    *   **Action**: Provision the raw Kubernetes API.
    *   **GKE**: `gcloud container clusters create...`
    *   **Homelab**: `k3s server`
2.  **Layer 0.5 (The Hydration)**
    *   **Action**: Run `./bootstrap.sh --target [gke|homelab]`
    *   **Step A**: Install **Gitea** (Helm) into the `gitea` namespace.
    *   **Step B**: Configure Gitea (Create Admin, Token).
    *   **Step C**: **Hydrate** the repository.
        *   The script takes the local `nordri` checkout.
        *   It selects the correct overlay (`envs/gke` or `envs/homelab`).
        *   It pushes the *Resolved Configuration* to the internal Gitea (`http://gitea-http/nordri.git`).
3.  **Layer 1 (The Ignition)**
    *   **Action**: Install **ArgoCD**.
    *   **Step A**: Argo is installed via Helm.
    *   **Step B**: Argo is configured with the internal Gitea as a "Repository".
    *   **Step C**: The "Root Application" is applied, pointing to `HEAD` of the internal Gitea.
4.  **Layer 2+ (The Expansion)**
    *   **Action**: ArgoCD takes over.
    *   It sees the `Application` manifests in the internal Gitea.
    *   It installs Crossplane, Traefik, Cert-Manager, etc.

## The Architecture

```mermaid
graph TD
    Local[Local Machine] -->|1. Bootstrap Script| Cluster[Kubernetes Cluster]
    
    subgraph Cluster
        subgraph Layer 0.5
            SeedGit[Seed Gitea]
        end
        
        subgraph Layer 1
            Argo[ArgoCD Controller]
        end
        
        subgraph Layer 2
            Traefik[Vegvísir Gateway]
            Crossplane[Crossplane]
            Apps[Applications]
        end
    end

    Local -->|2. Pushes Hydrated Config| SeedGit
    Local -->|3. Installs| Argo
    Argo -->|4. Syncs from| SeedGit
    Argo -->|5. Deploys| Traefik
    Argo -->|5. Deploys| Crossplane
    Argo -->|5. Deploys| Apps
```

## Repository Structure

To support this "Hydration", the source code is structured to separate shared platform logic from environment specifics.

```text
/nordri
  /platform        # Shared Helm Charts / Kustomize Bases
    /argocd        # The App-of-Apps definition
    /traefik       # Base Traefik config
    /crossplane    # Base Crossplane config

  /envs            # Environment Overrides
    /gke
      /values.yaml # "Enable Cloud Armor", "Use GCS"
    /homelab
      /values.yaml # "Enable NodePort", "Use Garage"
```

## Why this Approach?

1.  **Environment Isolation**: The GKE cluster has absolutely no knowledge of the Homelab cluster, and vice-versa. There is no shared "Master Config" that can accidentally break both.
2.  **Offline Capability**: The Homelab requires no connection to GitHub.com to operate or recover, once the bootstrap script pushes the local files.
3.  **Inspectable State**: The "Seed Gitea" contains the exact state of the cluster. You can verify exactly what manifests Argo is applying by looking at the internal Gitea UI.
4.  **Standardization**: Both environments enable the "Platform" the same way, differing only in the hydration values.
