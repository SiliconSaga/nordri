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
# Export it even if `gcloud config set project` is already done — the
# verification commands further down interpolate ${GCP_PROJECT}, and an unset
# value silently targets gs://-velero rather than failing.
#
# Note `gcloud config get-value` prints the literal "(unset)" rather than
# nothing when no project is configured, so check for it explicitly: an
# unchecked value gives you a bucket named "(unset)-velero".
GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "$GCP_PROJECT" || "$GCP_PROJECT" == "(unset)" ]]; then
  echo "No GCP project configured. Run: gcloud config set project PROJECT_ID" >&2
  return 1 2>/dev/null || exit 1
fi
export GCP_PROJECT
echo "Using project: $GCP_PROJECT"   # confirm this is the one you expect

# The script's defaults are for a scratch cluster (nordri-test, $GCP_ZONE), so
# an existing cluster needs all three named. Find yours with:
#   gcloud container clusters list --project="$GCP_PROJECT" --format='table(name,location)'
export GKE_CLUSTER_NAME=ttf-cluster
export GKE_CLUSTER_LOCATION=us-east1-d

./gke-provision.sh velero-setup
```

For the SiliconSaga platform cluster as of 2026-08-31, those values are
`teralivekubernetes` / `ttf-cluster` / `us-east1-d`, and Workload Identity is
already enabled (`teralivekubernetes.svc.id.goog`). None of the three match the
script's defaults, and a workstation's `gcloud config` may well point somewhere
else entirely — **echo the project before running and confirm it is the one you
mean**, because every name derived from it (the bucket, the service account, the
IAM member) inherits the mistake silently.

It locates the cluster and reads its Workload Identity pool in one call, failing
with the cluster list if the location is wrong and separately if Workload Identity
is off — the binding is silently useless without it. Then it creates
`gs://<project>-velero` in the cluster's own region (buckets take a region or
multi-region, never a zone), creates the `velero` service account, and binds the
Kubernetes SA `velero/velero` to it.

Permissions are split deliberately:

- **Bucket-scoped** `roles/storage.objectAdmin` on `gs://<project>-velero` only.
- **Project-scoped** custom role `velero.server`, holding the ten `compute.*`
  snapshot permissions the GCP plugin documents plus `iam.serviceAccounts.signBlob`.
  Not `roles/compute.storageAdmin`, which confers full control of every disk and
  image in the project — far more than taking snapshots needs.

`signBlob` is required rather than optional: Velero signs URLs with it, and without
it `velero backup logs`, `backup download` and `backup describe` all fail —
including the verification below.

Re-running the command updates the custom role in place, so it is also the repair
path for permission drift. If an earlier setup granted the broad
`roles/compute.storageAdmin`, the script reports it and prints the revoke command
rather than removing the binding silently.

### Scope: these resources are project-level, not cluster-level

The Workload Identity pool is `<project>.svc.id.goog`, so the member
`<project>.svc.id.goog[velero/velero]` matches **every** cluster in the project.
The service account and the bucket are therefore shared by all of them.

That is why `gke-provision.sh delete` removes neither. Deleting the service account
during one cluster's teardown would break Velero on every other cluster in the
project; deleting the bucket would discard the backups that exist precisely to
survive a cluster's loss. Both are left with the manual commands printed, to run
only after confirming nothing else uses them.

GKE calls this **identity sameness**: any cluster in the project running a pod as
`velero/velero-server` can impersonate this service account and read or write the
whole backup bucket.

> **⚠ Not mitigated today.** The IAM condition below was written to close this and
> **does not work on this cluster**. Proven live on 2026-09-01: with only the
> conditioned binding, the token exchange fails with `Permission
> 'iam.serviceAccounts.getAccessToken' denied` and the BackupStorageLocation stays
> `Unavailable`. An *unconditioned* binding for the same member fixes it, so the
> condition is what never matches — `request.auth.claims.google.providerId` appears
> not to be populated for plain GKE Workload Identity here.
>
> `velero-setup` therefore creates **both** bindings, and the unconditioned one is
> what Velero actually authenticates with. Acceptable while `ttf-cluster` is the
> only cluster in the project. **Revisit before a second one exists** — either find
> the claim GKE really sets, or give each cluster its own GSA *and* KSA name.

**The KSA is `velero-server`, not `velero`.** The chart appends `-server` to the
release name, so a binding for `[velero/velero]` — as the original design doc
specified — targets a ServiceAccount that does not exist. Nothing errors: the
binding is accepted and authentication simply fails later, with a message about
the BackupStorageLocation rather than about identity.

The intended (currently ineffective) condition pins the binding to one cluster's
provider id:

```
request.auth.claims.google.providerId ==
  'https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/<cluster>'
```

The KSA stays `velero/velero`, so no manifest change and no per-cluster rename are
needed. The location is read from the cluster itself rather than from `GCP_ZONE`,
because a regional cluster's location is its region and a wrong value produces a
condition that never matches — which fails at backup time, not at setup time.

**If you ran an earlier version of this script**, it created the same binding with
no condition. IAM evaluates bindings as a union, so that one still grants every
cluster and makes the condition ineffective. `velero-setup` detects it and prints
the `remove-iam-policy-binding --condition=None` command; it does not remove it for
you, since revoking an IAM binding is not something a setup command should do
unannounced.

The service account is still not deleted on teardown: several clusters may hold
separate conditional bindings on it. If a second cluster ever backs up into this
bucket, give each a distinct `BackupStorageLocation` `prefix` so their backups do
not interleave in one path.

`bootstrap.sh gke` then substitutes `$GCP_PROJECT` into the Application at hydration
time and fails closed if it is unset or if any placeholder survives.

## Rehydrating an existing cluster

`./update-embedded-git.sh gke` is the day-2 path and is the one to use for a
config change; `bootstrap.sh` is for a cluster that does not have Gitea/ArgoCD yet.
Both stamp the project through the same `lib/patch-velero.sh`, so neither can push
an unsubstituted manifest.

Three things worth knowing before running it:

- **It pushes your local working tree, on whatever branch it is checked out.**
  `nordri`, `nidavellir`, `mimir` and `heimdall` are each hydrated from their
  sibling checkout, so an unmerged branch in any of them goes to the cluster.
  Check with `git -C ../<component> branch --show-current` first.
- **Identical content is a no-op.** Each hydration is a fresh orphan commit, so the
  SHA always changes, but ArgoCD compares rendered manifests against live state
  rather than revisions — no diff means no sync and nothing restarts.
- **Velero itself is the exception, by design.** This change alters its Application
  (plugin image, GCS backend, schedule, ServiceMonitor), so ArgoCD will re-sync it
  and the Velero pod will restart once. That is the intended effect. The Application
  keeps the name `velero` across the file rename, so it is updated in place rather
  than pruned and recreated.

`GCP_PROJECT` is required only for `gke`. The `homelab` target returns before the
check, and on `gke` a configured `gcloud config set project` satisfies it without
an export.

## Status: live and proven (2026-09-01)

First real backup ran end to end on `ttf-cluster`. `BackupStorageLocation default`
is `Available`, a verification backup Completed 98/98 items, and the objects were
confirmed present in `gs://teralivekubernetes-velero/backups/` — a `Completed`
phase alone would not have proven the bucket was written.

Four things had to be fixed to get there, all of them silent in different ways.
They are recorded because each will look like a different problem next time:

| Symptom | Cause |
|---|---|
| `ImagePullBackOff` on `velero-upgrade-crds`, sync stalls | Chart's CRD hook pulls `bitnamilegacy/kubectl:<cluster-version>`; no `1.35` tag exists. Fixed by pinning the tag *and* disabling the hook. |
| BSL `Unavailable`: `config has invalid keys [project]` | `project` is valid on the volumeSnapshotLocation, not the BackupStorageLocation. Same provider, two plugins, two schemas. |
| BSL `Unavailable`: `serviceAccount is expected...` | Under Workload Identity the object-store plugin must be told which GSA to sign as. This is what `iam.serviceAccounts.signBlob` is for. |
| `iam.serviceAccounts.getAccessToken denied` | Binding targeted `[velero/velero]`; the chart's KSA is `velero-server`. Plus the IAM condition never matches — see the warning above. |

A restart of the Velero deployment was needed after the IAM changes: the pod
caches its credentials at startup, so a correct binding does not take effect until
it restarts.

## Verifying — do not skip this

An install that looks healthy is exactly what was wrong before, so check the two
things that actually prove it works.

```bash
kubectl -n velero get backupstoragelocation default
# PHASE must be Available.

velero backup create verify-$(date +%s) --include-namespaces velero --wait
velero backup get
```

That first backup is an **object-storage smoke test only**. The `velero` namespace
holds no PVC, so it exercises the bucket, the credentials and the plugin — and
touches none of the `compute.*` snapshot permissions, which are the newest and
therefore likeliest part of the IAM setup to be wrong.

To exercise those, back up a namespace that actually has a bound PVC and confirm a
snapshot was taken:

```bash
# Pick a namespace with a bound PVC.
kubectl get pvc -A

# Set this to the namespace you picked; the rest is copy-pasteable as-is.
# Quoted, because an unquoted <placeholder> is a shell redirection — bash tries
# to open a file by that name and fails before velero is ever invoked.
NAMESPACE="CHANGE-ME"
BACKUP_NAME="verify-snap-$(date +%s)"

velero backup create "$BACKUP_NAME" \
  --include-namespaces "$NAMESPACE" --snapshot-volumes --wait

# "Volume snapshots: N of N completed successfully" — 0 completed, or the
# section missing entirely, means the custom role is not in effect.
velero backup describe "$BACKUP_NAME" --details
```

`backup describe` needs `iam.serviceAccounts.signBlob`, so a permissions error at
this step points at the custom role rather than at the backup itself.

If the location is `Unavailable`, read the reason before guessing — it distinguishes
a missing bucket from a credential problem from a plugin mismatch:

```bash
kubectl -n velero describe backupstoragelocation default   # .status.message
kubectl -n velero logs deploy/velero
```

Then, if the logs point at authentication, check that the annotation is present and
names the right project:

```bash
kubectl -n velero get sa velero -o jsonpath='{.metadata.annotations}'
```

Then confirm objects actually landed in the bucket. A `Completed` backup with an
empty bucket is not a backup.

```bash
gcloud storage ls gs://${GCP_PROJECT}-velero/backups/
```

## What this does and does not cover

**Covers:** Kubernetes object state in every namespace *except* the ones the
schedule excludes, plus GCP persistent-disk snapshots for PVCs in scope. This is the
net for losing a cluster, a namespace, or a PV, including the Delete-reclaim-policy
losses that have already happened three times.

Exclusions fall into three groups, and only the first is automatic:

| Excluded | Why |
|---|---|
| `kube-system`, `kube-public`, `kube-node-lease`, `gmp-system`, `gmp-public`, `velero` | Cluster-managed or self-referential — recreated by GKE, bootstrap, or ArgoCD. |
| `ark` | 161Gi that is overwhelmingly game *install*, not saves. Needs a volume split **and** a Velero VolumePolicy before it can come back — see the comment in `velero-gke.yaml`. |
| `heimdall` | 21.5 GB of mostly Prometheus TSDB. Rewrites continuously, so it would dominate every daily incremental to protect 7-day-retention telemetry that is rebuilt from git. Accepted loss. |

**If you add a workload to any of these, it is not being backed up.** That matters
most for `heimdall`: it is excluded because it holds telemetry, so anything
non-reconstructible landing there would be silently unprotected.

### An included namespace does not mean every volume is snapshotted

Namespace scope and volume scope are two separate filters, and the second is easy to
miss. The `velero-volume-policy` ConfigMap skips **any PVC labelled
`backup.siliconsaga.org/content: reconstructible`**, wherever it lives — the
namespace being in scope does not save it.

Volume policies are the *final* filter in Velero's pipeline, ranking above
`snapshotVolumes: true`, so a matching `skip` wins. Its object still gets backed up;
only the disk contents are skipped, which is what lets a restore recreate an empty
PVC that the workload then refills from upstream.

Carrying the label today: `valheim-game` in `kubicvalheim`, `valheim-twinhenge` and
`valheim-valheim3` — the SteamCMD install, ~1.76 GB each, refetchable. Find them all
with:

```bash
kubectl get pvc -A -l backup.siliconsaga.org/content=reconstructible
```

Apply it to any volume that is a cache of something an upstream source can rebuild.
Do **not** apply it to anything authored in the cluster, because there is no second
copy — the skip is silent and a restore would hand back an empty volume.

Sizing as of 2026-09-01: 686 Gi provisioned across 46 PVCs, 117.7 GB actually used.
After the two exclusions above, roughly 100 GB — dominated by `artifactory`
(46.1 GB) and `jenkins` (32.5 GB). Measure it yourself with the kubelet stats
summary, which is a read and needs no port-forward:

```bash
kubectl get --raw "/api/v1/nodes/$NODE/proxy/stats/summary" \
  | jq -r '.pods[]? | .podRef.namespace as $ns | (.volume // [])[]
           | select(.pvcRef != null)
           | [$ns, .pvcRef.name, .usedBytes] | @tsv'
```

An unmounted PVC reports nothing there but is still snapshotted from its PV, so a
zero is not the same as free.

**Does not cover databases properly.** A snapshot of a live MySQL or Postgres volume
is *crash-consistent*, not transaction-consistent: restoring it is equivalent to
recovering from a power cut, and across multiple volumes the snapshots are not even
mutually consistent. Databases must keep their own engine-native backups — PXC
`xtrabackup` schedules, pgBackRest — and Velero is the second layer beneath them,
not a replacement.

For the shared Postgres cluster that layer is live: pgBackRest writes `repo1` to a
local PVC and `repo2` straight to its own GCS bucket, keyless over Workload
Identity, on its own schedule. See
[`mimir/docs/offsite-backups.md`](../../mimir/docs/offsite-backups.md) — including
the two-KSA IAM trap, which fails by reporting the repository healthy while no WAL
ever arrives.

**Retention.** 30 days of dailies. Neither the bucket nor the service account is
removed by `gke-provision.sh delete` — see the scope note above for why.

## CRDs are not managed by the chart here — `upgradeCRDs: false`

The chart ships a pre-install/pre-upgrade hook Job that re-applies Velero's CRDs.
It is disabled on GKE, and that has a consequence worth knowing before the next
chart bump.

**Why it is off.** The hook runs on *every* sync, including a values-only change,
and ArgoCD treats it as a hard gate — the sync sits on `waiting for completion of
hook batch/Job/velero-upgrade-crds` and never converges if the Job cannot start.
It had nothing to do: all 13 Velero CRDs have existed on this cluster since
2026-03-21, and `targetRevision` is not moving. It also happened to be broken —
its init container pulls `docker.io/bitnamilegacy/kubectl:<tag>` where the tag
defaults to the *cluster's* Kubernetes version, and no `1.35` tag exists in that
repo, so it sat in `ImagePullBackOff` and blocked the first real rollout.

**⚠ The trade.** Bumping `targetRevision` will no longer upgrade CRDs. If a future
chart version changes them, apply them by hand *before* the bump:

```bash
velero install --crds-only --dry-run -o yaml | kubectl apply -f -
```

Check the chart's release notes for CRD changes when bumping. If CRD churn ever
becomes routine, re-enable the hook rather than carrying a manual step — but keep
the `kubectl.image.tag` pin, which is what stops the hook breaking again on a
cluster whose Kubernetes version has no matching legacy image.

Both guards are deliberate and independent: the pin fixes the hook, and disabling
the hook stops a values-only change from ever being gated behind it.

## Monitoring

The chart's ServiceMonitor is enabled here, and heimdall carries the alerts
(`heimdall.velero` rule group) plus a **Heimdall Backups** dashboard. The rule that
matters most is `VeleroNoBackupsEverSucceeded`, an `absent()` guard on
`velero_backup_last_successful_timestamp`: that metric does not exist until a
backup has succeeded once, so every staleness comparison is silent on a Velero that
has never worked — precisely the state this whole page is about.

## A `PartiallyFailed` that never clears — look for an orphaned PV

This has now bitten once (2026-09-01/02) and is the failure mode most likely to
recur, because it is caused by the same Delete-reclaim losses this page exists to
protect against.

**Symptom.** Every scheduled backup finishes `PartiallyFailed` with `errors: 1`,
while the counts all look healthy — `1583/1583` items, `26/26` snapshots. The
`VeleroBackupStale` alert fires, and it is *correct* to fire:
`velero_backup_last_successful_timestamp` only advances on a fully `Completed`
backup, so one permanent error makes Velero look like it stopped running entirely.

**Cause.** A PV still in the cluster whose backing GCE disk is gone. Velero tries
to snapshot it every night and gets a 404 forever. Ours was
`backstage/data-backstage-postgresql-0`, left behind when the workload went away.

**Diagnosing it.** The phase does not say which item failed, and the error is not
in the CR — it is in the backup log in the bucket:

```bash
gcloud storage cp \
  "gs://${GCP_PROJECT}-velero/backups/<backup-name>/<backup-name>-logs.gz" /tmp/b.log.gz
zgrep -m5 'level=error' /tmp/b.log.gz
```

which names the item directly:

```
error getting volume info: rpc error: code = Unknown desc = googleapi:
Error 404: The resource '.../disks/pvc-aa7433da-...' was not found, notFound
```

**Finding them before Velero does.** Check in *both* directions. Listing disks
with no PV finds leaked disks; this finds the ones that break backups:

```bash
gcloud compute disks list --project="$GCP_PROJECT" --format='value(name)' | sort > /tmp/disks
kubectl get pv -o json | jq -r '
  .items[] | select(.spec.csi.volumeHandle != null)
  | [.metadata.name, (.spec.csi.volumeHandle | split("/") | last),
     (.spec.claimRef.namespace // "-"), (.spec.claimRef.name // "-")] | @tsv' \
| while IFS=$'\t' read -r pv disk ns claim; do
    grep -qx "$disk" /tmp/disks || echo "MISSING DISK: $pv  ($ns/$claim)"
  done
```

A PV/disk **count** mismatch is the same signal and is cheaper to spot — if there
are more PVs than disks, one of them is already poisoning every backup. Do not
wave it away as accounting noise; that is exactly how this went unnoticed.

Note the query skips legacy in-tree `gcePersistentDisk` PVs, which have no
`csi.volumeHandle` — `jenkins` and `fjordur-from-old-snapshot` are those. They
*are* still snapshotted normally; they just need checking by hand.

**Fixing it.** Delete the orphaned PV. Then prove it, rather than waiting for the
next scheduled run: fire a one-off backup with the same shape as the schedule
(same `resourcePolicy`, same `excludedNamespaces`) and confirm it reaches
`Completed`. A `PartiallyFailed` schedule with a `Completed` manual run of
identical shape means the cause is fixed and only the next scheduled run is
outstanding.

## Follow-ups

- **No object-storage size metric anywhere.** Velero does not expose one, and
  nothing on this cluster scrapes Cloud Monitoring, so there is no way today to
  chart what `gs://<project>-velero` is costing. The dashboard deliberately omits a
  bucket panel rather than shipping one that renders "No data" forever. Closing
  this means running `stackdriver-exporter` (or wiring GMP) to bring
  `storage.googleapis.com/storage/v2/total_bytes` into Prometheus — worth doing
  before retention is raised, since 30 days of daily snapshots is the kind of thing
  that shows up on a bill quietly.
  - Interim: a GCS **lifecycle rule** would bound growth independently of
    monitoring, and `gcloud storage du -s gs://<project>-velero` answers the
    question by hand.
- **A restore drill.** Nothing here is proven until a real restore has been done
  into a scratch namespace. A restore that produces an empty-but-working system
  looks identical to a successful one from the outside.
