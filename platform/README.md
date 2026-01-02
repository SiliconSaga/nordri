# Nordri Platform Definition

This directory contains the core infrastructure definitions (Layer 4 & 5) managed by ArgoCD.

## Structure

We use a **Kustomize-based App-of-Apps** pattern to handle environment differences.

```text
/platform
  /argocd          # The Root App-of-Apps definition
  /fundamentals    # Layer 4 Components (Traefik, Crossplane, etc.)
    /apps          # ArgoCD Application definitions (Helm Wrappers)
    /manifests     # Raw Kubernetes Resources (ClusterIssuers, Providers)
    /overlays      # Kustomize Overlays per Environment
      /gke         # Includes Apps specific to GKE (e.g., CertManager)
      /homelab     # Includes Apps specific to Homelab (e.g., Garage, Longhorn)
```

## How it Works

1.  **Bootstrap**: The `bootstrap.sh` script hydrates the repo and points the Root App to the correct overlay (e.g., `platform/fundamentals/overlays/homelab`).
2.  **Argo Sync**: ArgoCD syncs the `kustomization.yaml` in that overlay.
3.  **Application Creation**: The overlay includes the specific `Application` manifests from `apps/`.
4.  **Resource Creation**: The overlay includes raw manifests from `manifests/`.

## Important Notes

*   **Argonception**: Most YAML files in `apps/` are `kind: Application`. They tell Argo to sync *another* Helm chart (e.g., the official Traefik chart).
*   **Namespaces**: Any "loose" manifest (like `ClusterIssuer`) applied by the App-of-Apps will default to the `argocd` namespace unless explicitly namespaced in the file.
*   **Values**: Environment-specific values (e.g., LoadBalancer vs NodePort) are injected via the `envs/` directory, which the App-of-Apps or individual Applications reference.

## TODOs

* The Issuer uses a hardcoded email admin@yggdrasil.cloud and Gateway name traefik-gateway. You may want to templated these using Kustomize overlays in envs/ later if they vary significantly.
* We need to find a valid chart for Garage or write our own. We must deal with that before starting to test.
* Need to compare Crossplane versions with what worked in Mimir.
