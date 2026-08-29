# Velero on GKE — GCS + Workload Identity

**Status: implemented.** This page was a design TODO; it now describes what ships.
The homelab path is unchanged.

## What was wrong

`platform/fundamentals/apps/velero.yaml` was included by **both** overlays, but it
configures `velero-plugin-for-aws` against `garage.garage.svc.cluster.local:3900` —
a Service that only exists in the homelab overlay. On GKE that name does not
resolve, and bootstrap created a placeholder `velero-credentials` Secret with
literal `PLACEHOLDER` keys purely so the pod would not CrashLoopBackOff.

The result was the worst shape a backup system can take: **installed, running,
reporting healthy, and storing nothing.** A file comment claimed the URL was
"overridden to storage.googleapis.com in GKE"; no such patch existed.

There were also no `Schedule` objects at all, so even a correctly configured
Velero would have taken zero backups until someone ran one by hand.

## What ships now

| Concern | Homelab | GKE |
|---|---|---|
| File | `apps/velero-homelab.yaml` | `apps/velero-gke.yaml` |
| Plugin | `velero-plugin-for-aws` | `velero-plugin-for-gcp` |
| Provider | `aws` (Garage S3-compat) | `gcp` |
| Backend | `garage.garage.svc.cluster.local:3900` | `gs://<project>-velero` |
| Auth | HMAC key in `velero-credentials` | Workload Identity, no Secret |
| Volume snapshots | noop | GCP persistent-disk snapshots |
| Schedule | none | `daily-full`, 06:00 UTC, 30d TTL |

Each overlay includes exactly one of the two files. Keeping them separate is the
point — a single shared file is what produced the failure above.

## Setup

One-time, idempotent, and safe to run against a cluster that already exists — the
long-lived production cluster was not created by `gke-provision.sh`, so this is a
standalone action rather than a step inside `create`:

```bash
export GCP_PROJECT=<your-project-id>
./gke-provision.sh velero-setup
```

It verifies Workload Identity is enabled (failing loudly if not, because the IAM
binding is silently useless without it), creates `gs://<project>-velero`, creates
the `velero` service account, grants `roles/storage.objectAdmin` scoped to that one
bucket plus project-scoped `roles/compute.storageAdmin` for disk snapshots, and
binds the Kubernetes SA `velero/velero` to it.

`bootstrap.sh gke` then substitutes `$GCP_PROJECT` into the Application at hydration
time and fails closed if it is unset or if any placeholder survives.

## Verifying — do not skip this

An install that looks healthy is exactly what was wrong before, so check the two
things that actually prove it works.

```bash
kubectl -n velero get backupstoragelocation default
# PHASE must be Available. Unavailable means velero-setup has not taken effect —
# check the iam.gke.io/gcp-service-account annotation on the velero ServiceAccount.

velero backup create verify-$(date +%s) --include-namespaces velero --wait
velero backup get
```

Then confirm objects actually landed in the bucket. A `Completed` backup with an
empty bucket is not a backup.

```bash
gcloud storage ls gs://${GCP_PROJECT}-velero/backups/
```

## What this does and does not cover

**Covers:** Kubernetes object state cluster-wide, plus GCP persistent-disk snapshots
for PVCs in scope. This is the net for losing a cluster, a namespace, or a PV —
including the Delete-reclaim-policy losses that have already happened three times.

**Does not cover databases properly.** A snapshot of a live MySQL or Postgres volume
is *crash-consistent*, not transaction-consistent: restoring it is equivalent to
recovering from a power cut, and across multiple volumes the snapshots are not even
mutually consistent. Databases must keep their own engine-native backups — PXC
`xtrabackup` schedules, pgBackRest — and Velero is the second layer beneath them,
not a replacement.

**Retention.** 30 days of dailies. The bucket is deliberately **not** deleted by
`gke-provision.sh delete`; backups whose purpose is surviving the loss of a cluster
must outlive it. The service account is removed, since its Workload Identity binding
names that cluster's pool.

## Follow-ups

- **Alerting.** Velero exposes Prometheus metrics (`velero_backup_failure_total`,
  `velero_backup_last_successful_timestamp`). Nothing watches them yet, so a
  schedule that silently stops looks identical to one that works. This is the same
  failure class as the Valheim off-cluster backups, and it wants a heimdall rule —
  including an `absent()` guard, since a metric that never appears cannot trip a
  staleness comparison.
- **A restore drill.** Nothing here is proven until a real restore has been done
  into a scratch namespace. A restore that produces an empty-but-working system
  looks identical to a successful one from the outside.
