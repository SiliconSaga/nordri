# Nordri Platform Definition

This directory contains the core infrastructure definitions (Layer 4 & 5) managed by ArgoCD.

Note that this relies on the user having prepared their environment (see `dev_setup.md` in the Yggdrasil project), created a k3d cluster, and run the bootstrap script.

**Create the k3d cluster** (disable built-in Traefik since Nordri installs its own):

```bash
k3d cluster create refr-k8s \
  --port "8080:80@loadbalancer" --port "8443:443@loadbalancer" \
  --agents 2 --k3s-arg "--disable=traefik@server:*"
```

> For Rancher Desktop: disable Traefik via the GUI instead.

**Run the bootstrap** from within a compatible bash shell:

* Mac/Linux bash: `./bootstrap.sh <realm> <cluster>` (e.g. `./bootstrap.sh realm-siliconsaga homelab-nano76win11`)
* Windows: 
  * `cd "C:\Program Files\Git\bin"` or wherever Git Bash is installed
  * Run `bash` or `./bash.exe` if using a PowerShell terminal
  * `cd /d/Dev/GitWS/nordri` or wherever you cloned the repo
  * Run `./bootstrap.sh <realm> <cluster>`

### Accessing the Cluster

After bootstrapping, you can access the services:

#### Credentials

*   **Gitea**:
    *   User: `nordri-admin`. Not currently a runtime knob — downstream
        ArgoCD Application repoURLs hardcode this, so changing it would
        also require a hydration-time substitution pass that the script
        doesn't do today. Track via the OpenBAO migration.
    *   Password: stored in the Kubernetes Secret
        `gitea/gitea-admin-credentials`. Retrieve with:

        ```bash
        kubectl get secret -n gitea gitea-admin-credentials \
          -o jsonpath='{.data.password}' | base64 --decode
        ```

        On a **fresh cluster**, `bootstrap.sh` generates a strong random
        password, installs Gitea with it, and writes it to the Secret.

        An **existing cluster** is not a job for `bootstrap.sh`. One
        bootstrapped by the pre-Phase-3 code (its `nordri-root`
        Application reads the old `nordri-admin` repositories) is
        refused outright: a re-run would switch it to the new Git with no
        finalizer step, and the prune would delete what the old
        Applications deployed. Move it with
        `scripts/migrate.sh <realm> <cluster>` instead. If the cluster
        has no `gitea/gitea-admin-credentials` Secret yet (it predates
        the Secret-backed flow, or you rotated the password by hand),
        write the Secret with the live password first, as below; migrate
        and `update-embedded-git.sh` read it from there (or take a
        one-shot `GITEA_PASS=<live-password>`, which is not persisted).
        A wrong value fails loud with 401 rather than silently: rewrite
        the Secret with the right one and re-run.

        To **rotate** the password, change it in Gitea (UI or API), then
        write the Secret to match:

        ```bash
        kubectl create secret generic gitea-admin-credentials -n gitea \
          --from-literal=username=nordri-admin \
          --from-literal=password='<new-password>' \
          --dry-run=client -o yaml | kubectl apply -f -
        ```

        `update-embedded-git.sh` and any other consumers will pick up the
        new value from the Secret on the next run. Long-term, this whole
        flow is expected to migrate into OpenBAO once Nidavellir lands it.
*   **ArgoCD**:
    *   User: `admin`
    *   Password: Run the command below to retrieve it.

    ```bash
    kubectl -n argo get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode
    ```

#### Connectivity

If you have deployed the IngressRoutes (Layer 4), you can access them at:
*   **ArgoCD**: `http://argocd.localhost` (or loadbalancer IP)
*   **Gitea**: `http://gitea.localhost`
*   **Garage S3**: `http://s3.localhost` (S3 API Endpoint - Returns XML)
*   **Garage Web**: `http://garage.localhost` (Static Site Hosting - **Returns 404 by default** until a bucket is configured for website hosting)

If Ingress is not yet up (or you are debugging Layer 4), use Port Forwarding:

```bash
# ArgoCD
kubectl port-forward svc/argocd-server -n argo 8080:443
# Access at https://localhost:8080

# Gitea
kubectl port-forward svc/gitea-http -n gitea 3000:3000
# Access at http://localhost:3000

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
      /homelab     # Includes Apps specific to Homelab (e.g., Garage)
```

## How it Works

1.  **Bootstrap**: The `bootstrap.sh` script hydrates the Git repo from the user's workspace into the cluster, then points the Root App to the correct overlay (e.g., `platform/fundamentals/overlays/homelab`).
2.  **Argo Sync**: ArgoCD syncs the `kustomization.yaml` in that overlay.
3.  **Application Creation**: The overlay includes the specific `Application` manifests from `apps/`.
4.  **Resource Creation**: The overlay includes raw manifests from `manifests/`.

## Composition Patterns

Nordri exposes substrate patterns that downstream components (Heimdall, Mimir,
…) consume in their Crossplane compositions:

* **[Cluster identity](docs/cluster-identity.md)** — workspace-scoped
  `EnvironmentConfig/cluster-identity` provisioned per environment. Compositions
  read per-cluster facts (`storageClass`, `domain`, `environment`) from it via
  `function-environment-configs` so claims and templates stay
  environment-agnostic. Read this before authoring a new Composition.

## Important Notes

*   **Storage Strategy**: `local-path` (built-in to k3d/k3s) is the only storage class in use on every target except GKE, which uses its own CSI driver (Persistent Disk). `local-path` is node-local and does **not replicate** across nodes.
    *   **Longhorn was retired on 2026-08-26.** It had never provisioned a volume here, and its leftover admission webhook — `failurePolicy: Fail` on PVCs, with no healthy endpoint behind it — was rejecting every new PVC on the cluster at admission time. A cluster that once had it needs the webhook configurations deleted by hand; the homelab overlay carries the commands.
    *   **Distributed storage remains an open need**, not a solved one: `local-path` does not survive node loss, so a multi-node homelab or production target still wants Longhorn, Rook-Ceph, or similar. Re-adding one is a deliberate decision to make with eyes open — including that k3d containers lack `iscsid`, so Longhorn cannot work there at all.

*   **In-cluster `keycloak.localhost`**: On homelab a CoreDNS rewrite lets *pods* resolve `keycloak.localhost` to Traefik, so server-side OIDC flows (e.g. OpenBao's token exchange) can reach Keycloak at its homelab issuer. See **[Resolving keycloak.localhost inside the cluster](docs/keycloak-localhost-coredns.md)**.
*   **Argonception**: Most YAML files in `apps/` are `kind: Application`. They tell Argo to sync *another* Helm chart (e.g., the official Traefik chart).
*   **Namespaces**: Any "loose" manifest (like `ClusterIssuer`) applied by the App-of-Apps will default to the `argo` namespace unless explicitly namespaced in the file.
*   **Values**: Per-cluster values (environment, storage class, domain, GCP project...) live in the cluster-local `nordri/cluster-identity` ConfigMap, written by `bootstrap.sh` from the realm's cluster declaration. Nothing is stamped into the manifests that are hydrated to Git.

## Operation & Maintenance

### 1. Fast Iteration (`update-embedded-git.sh`)
To push changes to the cluster without re-running the full bootstrap (which can be slow), switch kubectl to the target cluster and run:
```bash
./update-embedded-git.sh realm-siliconsaga
```
It hydrates the component working trees (and the realm's `cluster/`), pushes them to the seed Gitea, recreating any repository the seed lost, and hard-refreshes every ArgoCD Application. On GKE, push over the seed's public route and name the context, so a mismatched current context is refused:
```bash
KUBE_CONTEXT=gke_<project>_<zone>_<cluster> GITEA_HOST=gitea.cmdbee.org GITEA_SCHEME=https \
  ./update-embedded-git.sh realm-siliconsaga
```
Then wait for the Applications to re-resolve their repositories (read-only; exits 1 on timeout):
```bash
scripts/argo-settle.sh
```

The seed's storage is ephemeral by design, so a seed that lost its repositories only needs the re-hydrate above. A seed whose Helm release is broken or in an older shape is reinstalled in bootstrap's exact shape, keeping its admin password, with `scripts/reseed-gitea.sh <realm> <cluster>`, then re-hydrated.

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

* The Issuer uses a hardcoded email admin@yggdrasil.cloud and Gateway name traefik-gateway. You may want to templated these using the cluster identity later if they vary significantly.
* Need to compare Crossplane versions with what worked in Mimir.
* Need to cover Velero in a later Day 2 step. Can fetch original details from outdated/setup.md