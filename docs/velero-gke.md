# Velero on GKE — Design Notes

## Context

The current `platform/fundamentals/apps/velero.yaml` targets homelab only: it uses
`velero-plugin-for-aws` against a Garage S3 endpoint. On GKE, bootstrap creates a
placeholder `velero-credentials` secret so the pod boots, but backups do not work.

Proper GKE support requires a separate environment-specific configuration using the
native GCP plugin and GCS as the backend.

## Target State

| Concern | Homelab (current) | GKE (target) |
|---|---|---|
| Plugin | `velero-plugin-for-aws` | `velero-plugin-for-gcp` |
| Provider | `aws` (Garage S3-compat) | `gcp` |
| Backend | `garage.garage.svc.cluster.local:3900` | GCS bucket |
| Auth | HMAC key secret | Workload Identity (no secret) |
| Volume snapshots | noop | GCP persistent disk snapshots |

The single `velero.yaml` cannot serve both environments cleanly. The fix is two
separate files with each overlay including only its own:

```
platform/fundamentals/apps/
    velero.yaml          ← rename to velero-homelab.yaml (or keep as-is for homelab)
    velero-gke.yaml      ← new, GCP plugin + GCS + Workload Identity

platform/fundamentals/overlays/
    homelab/kustomization.yaml  ← references velero.yaml (homelab)
    gke/kustomization.yaml      ← references velero-gke.yaml (GKE)
```

## Implementation Steps

### 1. GCS infrastructure (add to `gke-provision.sh` create action)

```bash
GCS_BUCKET="${GCP_PROJECT}-velero"

# Create bucket
gcloud storage buckets create gs://${GCS_BUCKET} \
    --location=$GCP_ZONE --uniform-bucket-level-access

# Create GCP service account
gcloud iam service-accounts create velero \
    --display-name "Velero backup operator"

# Grant object access on the bucket
gcloud storage buckets add-iam-policy-binding gs://${GCS_BUCKET} \
    --member=serviceAccount:velero@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/storage.objectAdmin

# Grant compute disk snapshot access
gcloud projects add-iam-policy-binding $GCP_PROJECT \
    --member=serviceAccount:velero@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/compute.storageAdmin

# Bind GCP SA → Kubernetes SA via Workload Identity
gcloud iam service-accounts add-iam-policy-binding \
    velero@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]"
```

Also add cleanup to the `delete` action:
```bash
gcloud iam service-accounts delete velero@${GCP_PROJECT}.iam.gserviceaccount.com --quiet || true
# Note: deliberately do NOT delete the bucket on cluster delete — backups should survive
# cluster recreation. Add a separate 'purge' action if bucket deletion is ever needed.
```

### 2. New `platform/fundamentals/apps/velero-gke.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argo
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://vmware-tanzu.github.io/helm-charts'
    chart: velero
    targetRevision: 11.3.1
    helm:
      values: |
        initContainers:
          - name: velero-plugin-for-gcp
            image: velero/velero-plugin-for-gcp:v1.11.0
            volumeMounts:
              - mountPath: /target
                name: plugins
        serviceAccount:
          server:
            annotations:
              iam.gke.io/gcp-service-account: velero@PROJECT_ID.iam.gserviceaccount.com
        configuration:
          backupStorageLocation:
            - name: default
              provider: gcp
              bucket: PROJECT_ID-velero
              config:
                project: PROJECT_ID
          volumeSnapshotLocation:
            - name: default
              provider: gcp
              config:
                project: PROJECT_ID
        credentials:
          useSecret: false
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The `PROJECT_ID` values above need to be either:
- Templated via a kustomize patch that injects `$GCP_PROJECT` at hydration time, or
- Committed as a separate env-specific values file

Consider adding a hydration step in `bootstrap.sh` that substitutes `PROJECT_ID` with
the actual `$GCP_PROJECT` value when copying to the Gitea hydration directory (similar
to how the kustomize overlay path is patched today).

### 3. Update `platform/fundamentals/overlays/gke/kustomization.yaml`

Replace `../../apps/velero.yaml` with `../../apps/velero-gke.yaml`.

### 4. Remove placeholder secret from `bootstrap.sh`

With Workload Identity, no `velero-credentials` secret is needed at all. Remove the
GKE placeholder secret block added as a temporary workaround.

## Side Effects / Benefits

- **kubectl image pin no longer needed for GKE** — the `kubectl.image.tag` workaround
  in velero.yaml is only required because of Bitnami's image policy change affecting
  the AWS plugin helper. The GCP plugin does not use this image. The pin can stay in
  `velero-homelab.yaml` but is absent from `velero-gke.yaml`.

- **Workload Identity means zero secret management** — no credentials stored in
  Kubernetes secrets, no rotation required. The Velero pod authenticates as the GCP
  service account via GKE's metadata server.

- **Volume snapshots actually work** — the GCP provider can snapshot GCP persistent
  disks in addition to backing up Kubernetes object state.

- **Backups survive cluster reset** — the GCS bucket is intentionally not deleted when
  the cluster is torn down, so backup history persists across `gke-provision.sh reset`.
