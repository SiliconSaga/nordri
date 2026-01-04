# Nordri Platform Definition

This directory contains the core infrastructure definitions (Layer 4 & 5) managed by ArgoCD.

### Accessing the Cluster

After bootstrapping, you can access the services:

#### Credentials
*   **Gitea**: `nordri-admin` / `nordri-password-change-me` (Defined in `bootstrap.sh`)
*   **ArgoCD**:
    *   User: `admin`
    *   Password: Run the command below to retrieve it.
    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    ```

#### Connectivity
If you have deployed the IngressRoutes (Layer 4), you can access them at:
*   **ArgoCD**: `http://argocd.localhost` (or loadbalancer IP)
*   **Gitea**: `http://gitea.localhost`

If Ingress is not yet up (or you are debugging Layer 4), use Port Forwarding:
```bash
# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at https://localhost:8080

# Gitea
kubectl port-forward svc/gitea-http -n gitea 3000:3000
# Access at http://localhost:3000
```

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
* Need to compare Crossplane versions with what worked in Mimir.
