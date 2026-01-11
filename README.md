# Nordri Platform Definition

This directory contains the core infrastructure definitions (Layer 4 & 5) managed by ArgoCD.

Note that this relies on the user having prepared their environment (see `dev_setup.md` in the Yggdrasil project) and having run the bootstrap.sh script from within a compatible bash shell.

* Mac/Linux bash: `./bootstrap.sh`
* Windows: 
  * `cd "C:\Program Files\Git\bin"` or wherever Git Bash is installed
  * Run `bash` or `./bash.exe` if using a PowerShell terminal
  * `cd /d/Dev/GitWS/nordri` or wherever you cloned the repo
  * Run `./bootstrap.sh`

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
*   **Longhorn**: `http://longhorn.localhost`
*   **Garage S3**: `http://s3.localhost` (S3 API Endpoint - Returns XML)
*   **Garage Web**: `http://garage.localhost` (Static Site Hosting - **Returns 404 by default** until a bucket is configured for website hosting)

If Ingress is not yet up (or you are debugging Layer 4), use Port Forwarding:

```bash
# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at https://localhost:8080

# Gitea
kubectl port-forward svc/gitea-http -n gitea 3000:3000
# Access at http://localhost:3000

# Longhorn
kubectl port-forward svc/longhorn-frontend -n longhorn-system 8000:80
# Access at http://localhost:8000

# Garage S3
kubectl port-forward svc/garage -n garage 3900:3900
# Access at http://localhost:3900
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

1.  **Bootstrap**: The `bootstrap.sh` script hydrates the Git repo from the user's workspace into the cluster, then points the Root App to the correct overlay (e.g., `platform/fundamentals/overlays/homelab`).
2.  **Argo Sync**: ArgoCD syncs the `kustomization.yaml` in that overlay.
3.  **Application Creation**: The overlay includes the specific `Application` manifests from `apps/`.
4.  **Resource Creation**: The overlay includes raw manifests from `manifests/`.

## Important Notes

*   **Argonception**: Most YAML files in `apps/` are `kind: Application`. They tell Argo to sync *another* Helm chart (e.g., the official Traefik chart).
*   **Namespaces**: Any "loose" manifest (like `ClusterIssuer`) applied by the App-of-Apps will default to the `argocd` namespace unless explicitly namespaced in the file.
*   **Values**: Environment-specific values (e.g., LoadBalancer vs NodePort) are injected via the `envs/` directory, which the App-of-Apps or individual Applications reference.

## Operation & Maintenance

### 1. Fast Iteration (`update.sh`)
To push changes to the cluster without re-running the full bootstrap (which can be slow):
1.  Edit files in `platform/` or `envs/`.
2.  Run:
    ```bash
    ./update.sh homelab
    ```
    This hydrates the configuration, pushes it to the internal Gitea, and triggers an ArgoCD sync.

### 2. Validation (`validate.py`)
To verify the health of all platform components (Pods, Ingress, Storage):
```bash
pip install -r requirements.txt
python validate.py
```

### 3. Garage Initialization (One-Time)

Garage requires an initial layout assignment to function. This is NOT handled by Helm/ArgoCD automatically.
If you reset the cluster, run:
```bash
# Assign all nodes to zone 'dc1' with 1GB capacity
kubectl exec -n garage garage-0 -- /garage layout assign -z dc1 -c 1G <NODE_ID_1> <NODE_ID_2> ...

# Apply changes
kubectl exec -n garage garage-0 -- /garage layout apply --version 1
```

*(You can get Node IDs via `/garage status`)*.

### 4. Testing Crossplane

For testing Crossplane Compositions (Infrastructure Logic), we recommend **KUTTL** (Kubernetes Test Tool).
*   It allows declarative testing (YAML) of infrastructure claims.
*   See [jonashackt/crossplane-kuttl](https://github.com/jonashackt/crossplane-kuttl) for examples.

## TODOs

* The Issuer uses a hardcoded email admin@yggdrasil.cloud and Gateway name traefik-gateway. You may want to templated these using Kustomize overlays in envs/ later if they vary significantly.
* Need to compare Crossplane versions with what worked in Mimir.
* Need to cover Velery in a later Day 2 step. Can fetch original details from outdated/setup.md