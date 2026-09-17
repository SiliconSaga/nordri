#!/bin/bash
# GKE Test Cluster Provisioning Script
#
# Creates a fresh GKE Standard cluster suitable for a full Nordri + Nidavellir
# bootstrap run. Use this for testing before touching the production cluster.
#
# Prerequisites:
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT
#
# Usage:
#   ./gke-provision.sh [create|delete|credentials|velero-setup|openbao-seal-setup|openbao-backup-setup]
#
# After creating the cluster:
#   ./bootstrap.sh gke
#
# To start over with a clean cluster (recommended over fighting finalizers):
#   ./gke-provision.sh delete   # then re-run create
#
# After testing:
#   ./gke-provision.sh delete

set -e

# `gcloud config get-value` prints the literal string "(unset)" — on stdout, not
# stderr — when a property has no value. It is NOT empty, so a plain -z check
# lets it through, and the value then propagates into everything derived from it:
# a bucket named `(unset)-velero`, an IAM member `(unset).svc.id.goog[...]`.
# Normalise it to empty so the guards below actually guard.
gcloud_config_value() {
    local v
    v="$(gcloud config get-value "$1" 2>/dev/null)" || return 0
    [[ "$v" == "(unset)" ]] && return 0
    printf '%s' "$v"
}

# Retry a gcloud IAM call that can transiently fail while a just-created service
# account propagates. Separate from the wait loop in velero-setup because the
# policy backends propagate INDEPENDENTLY — the storage IAM service can still be
# rejecting a member that project IAM already accepts, so waiting once up front
# is not sufficient on its own.
#
# Retries anything, but only worth wrapping around binding calls; a genuine
# permission or typo error just burns the attempts and then reports itself.
retry_gcloud() {
    local attempts=6 delay=5 n=1 out
    while :; do
        if out="$("$@" 2>&1)"; then
            [[ -n "$out" ]] && printf '%s\n' "$out"
            return 0
        fi
        if [[ $n -ge $attempts ]]; then
            printf '%s\n' "$out" >&2
            return 1
        fi
        # stderr, not stdout: every call site sends stdout to /dev/null to
        # suppress gcloud's own chatter, which would swallow this line too and
        # make a run that retried five times look identical to one that did not.
        printf "   ⏳ attempt %d/%d failed, retrying in %ds...\n" "$n" "$attempts" "$delay" >&2
        sleep "$delay"
        n=$(( n + 1 ))
    done
}

CLUSTER_NAME="${GKE_CLUSTER_NAME:-nordri-test}"
GCP_PROJECT="${GCP_PROJECT:-$(gcloud_config_value project)}"
GCP_ZONE="${GCP_ZONE:-$(gcloud_config_value compute/zone)}"
NODE_COUNT="${GKE_NODE_COUNT:-3}"
MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-standard-2}"
DISK_TYPE="${GKE_DISK_TYPE:-pd-standard}"
DISK_SIZE="${GKE_DISK_SIZE:-50}"
K8S_VERSION="${GKE_K8S_VERSION:-latest}"

if [[ -z "$GCP_PROJECT" ]]; then
    echo "❌ GCP_PROJECT not set and gcloud default project is empty."
    echo "   Run: gcloud config set project YOUR_PROJECT"
    echo "   Or:  export GCP_PROJECT=your-project-id"
    exit 1
fi

ACTION="${1:-create}"

echo "🔧 GKE cluster: $CLUSTER_NAME"
echo "   Project: $GCP_PROJECT"
echo "   Zone:    $GCP_ZONE"
echo "   Nodes:   $NODE_COUNT x $MACHINE_TYPE ($DISK_SIZE GB $DISK_TYPE)"

case "$ACTION" in

create)
    echo ""
    echo "🚀 Creating GKE cluster..."
    gcloud container clusters create "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE" \
        --num-nodes="$NODE_COUNT" \
        --machine-type="$MACHINE_TYPE" \
        --disk-type="$DISK_TYPE" \
        --disk-size="$DISK_SIZE" \
        --cluster-version="$K8S_VERSION" \
        --release-channel=None \
        --no-enable-autoupgrade \
        --no-enable-autorepair \
        --workload-pool="${GCP_PROJECT}.svc.id.goog" \
        --enable-ip-alias \
        --no-enable-master-authorized-networks

    echo ""
    echo "🔑 Fetching credentials..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE"

    echo ""
    echo "✅ Cluster ready. kubectl context is now: $(kubectl config current-context)"
    echo ""
    echo "Next: ./gke-provision.sh velero-setup   (backup storage + IAM)"
    echo "      ./bootstrap.sh gke"
    echo ""
    echo "⚠️  Remember: this cluster costs money. Delete it when done:"
    echo "   ./gke-provision.sh delete"
    ;;

velero-setup)
    # One-time GCS + IAM setup for Velero on GKE. Deliberately a SEPARATE action
    # rather than a step inside `create`: the long-lived production cluster was not
    # made by this script, and this needs to run against it too. Every step is
    # idempotent, so re-running is safe and is the way to repair drift.
    # Bucket name is NOT overridable. velero-gke.yaml derives it from the project
    # at hydration time, so a VELERO_BUCKET override here would create one bucket
    # and leave Velero reading from another — silently, which is this whole
    # change's failure mode. One derivation, one source of truth.
    VELERO_BUCKET="${GCP_PROJECT}-velero"
    VELERO_SA="velero@${GCP_PROJECT}.iam.gserviceaccount.com"
    VELERO_ROLE="velero.server"

    echo ""
    echo "🪣 Setting up Velero backup storage..."
    echo "   Service account: ${VELERO_SA}"
    echo ""

    # `--location` rather than `--zone`, because a REGIONAL cluster cannot be
    # addressed by zone: describe fails outright. The production cluster was not
    # created by this script and may well be regional, so defaulting to
    # GCP_ZONE and swallowing the error would have reported "Workload Identity
    # is not enabled" for a cluster that simply was not found — the wrong cause,
    # which is the failure mode this whole branch keeps trying to remove.
    #
    # GKE_CLUSTER_LOCATION overrides; GCP_ZONE remains the default so the
    # create-then-setup path on a zonal cluster needs no extra variable.
    CLUSTER_LOCATION="${GKE_CLUSTER_LOCATION:-$GCP_ZONE}"

    # One describe, two values, and the failure is NOT swallowed. This is both
    # the existence check and the Workload Identity check, so a bad location, a
    # missing cluster and a genuine WI-disabled cluster each report themselves.
    echo "🔍 Locating cluster $CLUSTER_NAME in $CLUSTER_LOCATION..."
    if ! CLUSTER_INFO="$(gcloud container clusters describe "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" --location="$CLUSTER_LOCATION" \
        --format='value(workloadIdentityConfig.workloadPool,location)')"; then
        echo "❌ Could not describe cluster '$CLUSTER_NAME' at location '$CLUSTER_LOCATION'." >&2
        echo "   A regional cluster must be addressed by its REGION, a zonal one by its zone." >&2
        echo "   List them with:" >&2
        echo "     gcloud container clusters list --project=$GCP_PROJECT --format='table(name,location)'" >&2
        echo "   Then re-run with:  GKE_CLUSTER_LOCATION=<location> $0 velero-setup" >&2
        exit 1
    fi
    # `cut -f`, NOT awk. `value(a,b)` emits the two fields TAB-separated, and
    # when Workload Identity is disabled the first field is empty — so the line
    # begins with a tab. awk splits on runs of whitespace and discards leading
    # blanks, so `$1` would be the LOCATION and `$2` empty: WI_POOL would come
    # back non-empty, the "is Workload Identity on?" check would pass on a
    # cluster where it is off, and CLUSTER_LOCATION would be empty going into
    # the IAM condition. Exactly inverted. cut is tab-delimited and keeps empty
    # fields, so the disabled case stays visible.
    WI_POOL="$(printf '%s' "$CLUSTER_INFO" | cut -f1)"
    # Prefer the location gcloud reports over the one we asked with — they match
    # today, but the reported value is what the IAM condition must embed.
    CLUSTER_LOCATION="$(printf '%s' "$CLUSTER_INFO" | cut -f2)"

    if [[ -z "$WI_POOL" ]]; then
        echo "❌ Workload Identity is not enabled on cluster '$CLUSTER_NAME'."
        echo "   Velero on GKE authenticates through it. Enable with:"
        echo "     gcloud container clusters update $CLUSTER_NAME \\"
        echo "       --project=$GCP_PROJECT --location=$CLUSTER_LOCATION \\"
        echo "       --workload-pool=${GCP_PROJECT}.svc.id.goog"
        exit 1
    fi
    echo "   ✅ Workload pool: $WI_POOL  (location: $CLUSTER_LOCATION)"

    # Buckets take a REGION or multi-region, never a zone, so a zonal cluster's
    # location has to be reduced to its region. Derived from the cluster rather
    # than from GCP_ZONE so the bucket lands beside the data it backs up.
    #
    # The reduction is conditional on purpose: `${loc%-*}` applied blindly turns
    # the REGION `us-central1` into `us`, which is a valid multi-region and would
    # therefore be accepted — silently placing the bucket on another continent's
    # billing footprint instead of erroring. Only strip when the value actually
    # looks like a zone (trailing -<letter>).
    if [[ "$CLUSTER_LOCATION" =~ ^(.*)-[a-z]$ ]]; then
        VELERO_BUCKET_LOCATION="${VELERO_BUCKET_LOCATION:-${BASH_REMATCH[1]}}"
    else
        VELERO_BUCKET_LOCATION="${VELERO_BUCKET_LOCATION:-$CLUSTER_LOCATION}"
    fi
    echo "   Bucket:          gs://${VELERO_BUCKET} (${VELERO_BUCKET_LOCATION})"

    echo "🪣 Creating bucket (skipped if it already exists)..."
    if gcloud storage buckets describe "gs://${VELERO_BUCKET}" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Bucket already exists."
    else
        gcloud storage buckets create "gs://${VELERO_BUCKET}" \
            --project="$GCP_PROJECT" \
            --location="$VELERO_BUCKET_LOCATION" \
            --uniform-bucket-level-access
        echo "   ✅ Bucket created."
    fi

    echo "👤 Creating service account (skipped if it already exists)..."
    if gcloud iam service-accounts describe "$VELERO_SA" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Service account already exists."
    else
        gcloud iam service-accounts create velero \
            --project="$GCP_PROJECT" \
            --display-name "Velero backup operator"
        echo "   ✅ Service account created."

        # A freshly created service account is not immediately usable as an IAM
        # MEMBER. `describe` starts answering almost at once, but the policy
        # backends reject it for a while longer with a flat
        #   HTTPError 400: Service account ... does not exist
        # which reads like the create silently failed. Observed on the first real
        # run of this action: the bucket grant two lines below failed that way
        # against a service account that had just been created successfully.
        #
        # Poll a real binding target rather than `describe`, since describe is
        # the thing that lies here.
        printf "   ⏳ Waiting for the service account to propagate to IAM"
        for _ in $(seq 1 30); do
            if gcloud iam service-accounts get-iam-policy "$VELERO_SA" \
                --project="$GCP_PROJECT" >/dev/null 2>&1; then
                printf " ready\n"
                break
            fi
            printf "."
            sleep 2
        done
    fi

    # Object access is scoped to the one bucket rather than project-wide.
    echo "🔐 Granting object access on the bucket..."
    retry_gcloud gcloud storage buckets add-iam-policy-binding "gs://${VELERO_BUCKET}" \
        --project="$GCP_PROJECT" \
        --member="serviceAccount:${VELERO_SA}" \
        --role=roles/storage.objectAdmin >/dev/null

    # A custom role rather than roles/compute.storageAdmin, which grants full
    # control of every disk and image in the project — far past taking snapshots.
    # These are the permissions the GCP plugin documents for its `velero.server`
    # role, minus the storage.objects.* entries, which are granted bucket-scoped
    # above instead of project-wide.
    #
    # iam.serviceAccounts.signBlob is REQUIRED, not optional hardening: Velero
    # signs URLs with it, and without it `velero backup logs`, `backup download`
    # and `backup describe` all fail — including the verification steps in
    # docs/velero-gke.md.
    VELERO_ROLE_PERMS="compute.disks.get,compute.disks.create,compute.disks.createSnapshot,\
compute.projects.get,compute.snapshots.get,compute.snapshots.create,\
compute.snapshots.useReadOnly,compute.snapshots.delete,compute.snapshots.setLabels,\
compute.zones.get,iam.serviceAccounts.signBlob"

    echo "🔐 Ensuring custom role ${VELERO_ROLE} (least privilege for snapshots)..."
    if gcloud iam roles describe "$VELERO_ROLE" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        # Update rather than skip: re-running is how permission drift is repaired,
        # and the permission list here is the source of truth.
        gcloud iam roles update "$VELERO_ROLE" \
            --project="$GCP_PROJECT" \
            --permissions="$VELERO_ROLE_PERMS" \
            --quiet >/dev/null
        echo "   ✅ Custom role updated."
    else
        gcloud iam roles create "$VELERO_ROLE" \
            --project="$GCP_PROJECT" \
            --title="Velero server" \
            --description="Least-privilege permissions for Velero disk snapshots and signed URLs." \
            --permissions="$VELERO_ROLE_PERMS" \
            --quiet >/dev/null
        echo "   ✅ Custom role created."
    fi

    echo "🔐 Granting ${VELERO_ROLE} to the service account..."
    retry_gcloud gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
        --member="serviceAccount:${VELERO_SA}" \
        --role="projects/${GCP_PROJECT}/roles/${VELERO_ROLE}" \
        --condition=None >/dev/null

    # If an earlier run of this script granted the broad role, say so rather than
    # revoking silently — removing an IAM binding someone may have come to depend
    # on is not something a setup command should do unannounced.
    if gcloud projects get-iam-policy "$GCP_PROJECT" \
        --flatten="bindings[].members" \
        --filter="bindings.role=roles/compute.storageAdmin AND bindings.members:${VELERO_SA}" \
        --format="value(bindings.role)" 2>/dev/null | grep -q .; then
        echo "⚠️  ${VELERO_SA} still holds the broad roles/compute.storageAdmin from an"
        echo "   earlier setup. The custom role above replaces it. Revoke with:"
        echo "     gcloud projects remove-iam-policy-binding $GCP_PROJECT \\"
        echo "       --member=serviceAccount:${VELERO_SA} \\"
        echo "       --role=roles/compute.storageAdmin --condition=None"
    fi

    # ── Workload Identity binding, scoped to THIS cluster ──
    #
    # The WI pool is PROJECT-level: the member `<project>.svc.id.goog[velero/velero-server]`
    # matches a `velero/velero-server` ServiceAccount in EVERY cluster in the
    # project. GKE calls this identity sameness, and unconditioned it means any
    # cluster here that happens to run a pod as velero/velero-server can
    # impersonate this account and read or write the whole backup bucket.
    #
    # The IAM condition pins the binding to one cluster by its provider id, so
    # the KSA name can stay `velero/velero-server` (no manifest change, no per-cluster
    # rename). The location comes from the cluster itself rather than GCP_ZONE,
    # since a regional cluster's location is its region.
    #
    # Still NOT deleted by the delete action: several clusters may hold separate
    # conditional bindings on this one service account, so removing it would
    # break the others.
    if [[ -z "$CLUSTER_LOCATION" ]]; then
        echo "❌ Could not read the location of cluster '$CLUSTER_NAME'." >&2
        echo "   Needed to scope the Workload Identity binding to this cluster." >&2
        exit 1
    fi
    VELERO_WI_PROVIDER="https://container.googleapis.com/v1/projects/${GCP_PROJECT}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
    # ⚠ THE IAM CONDITION BELOW DOES NOT WORK ON THIS CLUSTER, and is left in
    # place only because an UNCONDITIONED binding was added beside it by hand to
    # make Velero authenticate at all. Proven live on 2026-09-01: with only the
    # conditioned binding, the token exchange fails with
    #   Permission 'iam.serviceAccounts.getAccessToken' denied
    # and the BackupStorageLocation stays Unavailable. Adding an unconditioned
    # binding for the same member fixed it, so the condition itself is what never
    # matches — `request.auth.claims.google.providerId` appears not to be
    # populated for plain GKE Workload Identity here, whatever the docs imply.
    #
    # CONSEQUENCE: identity sameness is NOT mitigated right now. Any cluster in
    # this project running a pod as velero/velero-server can impersonate this
    # account. Acceptable while ttf-cluster is the only one; revisit before a
    # second cluster exists. Either find the claim GKE actually sets, or give
    # each cluster its own GSA and KSA name.
    #
    # The KSA is `velero-server`, NOT `velero`. The chart's serverServiceAccount
    # helper appends "-server" to the release name, so binding [velero/velero]
    # — as the original design doc specified — creates a binding for a
    # ServiceAccount that does not exist. Nothing errors: the binding is
    # accepted, the annotation on the real KSA points at the right GSA, and
    # authentication simply fails later with a message about the
    # BackupStorageLocation rather than about identity.
    echo "🔗 Binding velero/velero-server to $VELERO_SA, scoped to $CLUSTER_NAME..."
    retry_gcloud gcloud iam service-accounts add-iam-policy-binding "$VELERO_SA" \
        --project="$GCP_PROJECT" \
        --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero-server]" \
        --condition="expression=request.auth.claims.google.providerId=='${VELERO_WI_PROVIDER}',title=restrict-to-${CLUSTER_NAME}" >/dev/null

    # The unconditioned binding that actually works. See the warning above: the
    # conditioned one alone leaves Velero unable to fetch a token. Both are kept
    # so that if the condition is ever made to work, removing this line is the
    # only change needed.
    retry_gcloud gcloud iam service-accounts add-iam-policy-binding "$VELERO_SA" \
        --project="$GCP_PROJECT" \
        --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero-server]" \
        --condition=None >/dev/null

    # Earlier runs of this script bound `velero/velero` — the WRONG KSA, since
    # the chart's serverServiceAccount helper appends "-server". That binding
    # grants nothing useful (no such ServiceAccount exists) but it is still an
    # unconditioned workloadIdentityUser grant sitting on this GSA, so it is
    # worth reporting. Report rather than remove: deleting IAM bindings on
    # someone's behalf is not this script's job.
    #
    # Deliberately NOT flagging the unconditioned `velero-server` binding this
    # script creates a few lines above. That one is required — see the warning
    # there — and an advisory that fires on every single run, telling the
    # operator to delete the thing that makes Velero work, is worse than no
    # advisory at all. Re-point this check at velero-server if the conditioned
    # binding is ever made to work and the unconditioned one is dropped.
    #
    # Match the EXACT principal, not just the role. An earlier filter keyed on
    # role plus "condition title does not contain restrict-to-", which would
    # also match some other member, or another cluster's differently-titled
    # condition, and then print a removal command for a binding that does not
    # exist.
    #
    # gcloud's filter language cannot express "this member AND no condition at
    # all", so the policy is read as JSON and matched with jq. jq is optional
    # here: the check is advisory, so a machine without it gets a note rather
    # than a failure.
    VELERO_WI_STALE_MEMBER="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]"
    if ! command -v jq >/dev/null 2>&1; then
        echo "ℹ️  jq not found — skipping the check for a stale velero/velero binding."
        echo "   Inspect manually: gcloud iam service-accounts get-iam-policy $VELERO_SA"
    elif gcloud iam service-accounts get-iam-policy "$VELERO_SA" \
        --project="$GCP_PROJECT" --format=json 2>/dev/null \
        | jq -e --arg m "$VELERO_WI_STALE_MEMBER" '
            .bindings // []
            | map(select(
                .role == "roles/iam.workloadIdentityUser"
                and (.condition == null)
                and (.members // [] | index($m))
              ))
            | length > 0' >/dev/null; then
        echo "⚠️  A stale workloadIdentityUser binding for velero/velero exists on ${VELERO_SA}."
        echo "   That KSA name is wrong (the chart creates velero-server), so the binding"
        echo "   grants nothing — but it is dead IAM surface. Remove it:"
        echo "     gcloud iam service-accounts remove-iam-policy-binding $VELERO_SA \\"
        echo "       --project=$GCP_PROJECT --role=roles/iam.workloadIdentityUser \\"
        echo "       --member='serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]' \\"
        echo "       --condition=None"
    fi

    # Deliberately only the UNCONDITIONED stale binding above. gcloud removes a
    # binding by exact (member, role, condition) triple, so the --condition=None
    # command printed there does not touch a CONDITIONED velero/velero binding —
    # advising it for one would print a command that reports success-shaped
    # output while removing nothing. Earlier script versions created a
    # conditioned velero/velero binding too; it is equally dead, but removing it
    # needs its exact condition expression, so it is surfaced as an inspection
    # pointer rather than a copy-paste command that would not work.
    if command -v jq >/dev/null 2>&1 && gcloud iam service-accounts get-iam-policy "$VELERO_SA" \
        --project="$GCP_PROJECT" --format=json 2>/dev/null \
        | jq -e --arg m "$VELERO_WI_STALE_MEMBER" '
            .bindings // []
            | map(select(
                .role == "roles/iam.workloadIdentityUser"
                and (.condition != null)
                and (.members // [] | index($m))
              ))
            | length > 0' >/dev/null; then
        echo "ℹ️  A CONDITIONED workloadIdentityUser binding for velero/velero also exists."
        echo "   Also dead (wrong KSA name), but removing it needs its exact condition:"
        echo "     gcloud iam service-accounts get-iam-policy $VELERO_SA --project=$GCP_PROJECT"
    fi

    echo ""
    echo "✅ Velero storage ready."
    echo ""
    echo "Verify once ArgoCD has synced Velero:"
    echo "   kubectl -n velero get backupstoragelocation default"
    echo "   # PHASE should be Available. Unavailable means this setup has not"
    echo "   # taken effect — check the SA annotation on the velero ServiceAccount."
    echo ""
    echo "Then prove a backup actually works, rather than assuming:"
    echo "   velero backup create verify-\$(date +%s) --include-namespaces velero --wait"
    ;;

openbao-seal-setup)
    # One-time Cloud KMS + IAM setup so OpenBao on GKE unseals itself through
    # Workload Identity (realm ADR 0004; supersedes the manual-unseal posture of
    # ADR 0002). A separate action for the same reason velero-setup is: the
    # long-lived production cluster was not made by this script. Idempotent —
    # re-running repairs drift.
    #
    # The key ring and key NAMES are fixed, not overridable, because the OpenBao
    # composition in nidavellir hardcodes them alongside cluster-identity's
    # gcpProject/gcpRegion. Two sources of truth for a key name would mean an
    # OpenBao that cannot decrypt its own barrier.
    #
    # The REGION is read from the same manifest the composition reads, so the
    # key ring is created where the seal stanza will look for it. GCP_REGION
    # may be set for other gcloud reasons; if it disagrees, that is an error
    # rather than a second source of truth — an OpenBao whose seal names a key
    # in the wrong region is diagnosable only from the pod log.
    IDENTITY_MANIFEST="$(dirname "$0")/platform/fundamentals/manifests/cluster-identity-gke.yaml"
    SEAL_REGION="$(sed -n 's/^  gcpRegion:[[:space:]]*//p' "$IDENTITY_MANIFEST")"
    if [[ -z "$SEAL_REGION" ]]; then
        echo "❌ Could not read gcpRegion from $IDENTITY_MANIFEST." >&2
        echo "   The OpenBao composition renders that value into its seal stanza, so the key ring must be created there." >&2
        exit 1
    fi
    if [[ -n "${GCP_REGION:-}" && "$GCP_REGION" != "$SEAL_REGION" ]]; then
        echo "❌ GCP_REGION=$GCP_REGION disagrees with cluster-identity gcpRegion=$SEAL_REGION." >&2
        echo "   The seal key ring must live in the region cluster-identity names. Unset GCP_REGION," >&2
        echo "   or change gcpRegion in $IDENTITY_MANIFEST and re-hydrate before running this." >&2
        exit 1
    fi
    SEAL_KEYRING="openbao"
    SEAL_KEY="unseal"
    SEAL_SA="openbao-seal@${GCP_PROJECT}.iam.gserviceaccount.com"
    SEAL_KEY_RESOURCE="projects/${GCP_PROJECT}/locations/${SEAL_REGION}/keyRings/${SEAL_KEYRING}/cryptoKeys/${SEAL_KEY}"

    echo ""
    echo "🔐 Setting up OpenBao KMS auto-unseal..."
    echo "   Key:             ${SEAL_KEY_RESOURCE}"
    echo "   Service account: ${SEAL_SA}"
    echo ""

    # The API is off by default on a project that has never used KMS — this one
    # had not, as of 2026-09-07 — and every kms command below fails with
    # PERMISSION_DENIED until it is on. Enable explicitly rather than let gcloud
    # prompt, since this script also runs non-interactively.
    echo "🔌 Enabling the Cloud KMS API (no-op if already enabled)..."
    gcloud services enable cloudkms.googleapis.com --project="$GCP_PROJECT" >/dev/null

    echo "🔑 Ensuring key ring ${SEAL_KEYRING} in ${SEAL_REGION}..."
    if gcloud kms keyrings describe "$SEAL_KEYRING" --location="$SEAL_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Key ring already exists."
    else
        gcloud kms keyrings create "$SEAL_KEYRING" --location="$SEAL_REGION" --project="$GCP_PROJECT"
        echo "   ✅ Key ring created."
    fi

    # Symmetric encrypt/decrypt is what the gcpckms seal needs. Rotation is left
    # at the default (none); OpenBao re-wraps on demand and a rotated KMS key
    # version stays decryptable, so enabling rotation later is safe.
    echo "🔑 Ensuring crypto key ${SEAL_KEY}..."
    if gcloud kms keys describe "$SEAL_KEY" --keyring="$SEAL_KEYRING" --location="$SEAL_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Crypto key already exists."
    else
        gcloud kms keys create "$SEAL_KEY" --keyring="$SEAL_KEYRING" --location="$SEAL_REGION" \
            --project="$GCP_PROJECT" --purpose=encryption
        echo "   ✅ Crypto key created."
    fi

    echo "👤 Ensuring service account (skipped if it already exists)..."
    if gcloud iam service-accounts describe "$SEAL_SA" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Service account already exists."
    else
        gcloud iam service-accounts create openbao-seal \
            --project="$GCP_PROJECT" \
            --display-name "OpenBao KMS auto-unseal"
        echo "   ✅ Service account created."
        # Same propagation lag velero-setup hit: describe answers before the IAM
        # backends accept the account as a member. Poll a real policy read.
        printf "   ⏳ Waiting for the service account to propagate to IAM"
        SEAL_SA_READY=false
        for _ in $(seq 1 30); do
            if gcloud iam service-accounts get-iam-policy "$SEAL_SA" \
                --project="$GCP_PROJECT" >/dev/null 2>&1; then
                printf " ready\n"
                SEAL_SA_READY=true
                break
            fi
            printf "."
            sleep 2
        done
        if [[ "$SEAL_SA_READY" != "true" ]]; then
            printf " still not visible after 60s; continuing — the retried grants below report the real error if it persists.\n"
        fi
    fi

    # Scoped to the ONE key, not the key ring or project: this account can
    # wrap and unwrap OpenBao's barrier key and nothing else.
    echo "🔐 Granting encrypt/decrypt on the key..."
    retry_gcloud gcloud kms keys add-iam-policy-binding "$SEAL_KEY" \
        --keyring="$SEAL_KEYRING" --location="$SEAL_REGION" --project="$GCP_PROJECT" \
        --member="serviceAccount:${SEAL_SA}" \
        --role=roles/cloudkms.cryptoKeyEncrypterDecrypter >/dev/null

    # Workload Identity binding for the KSA the OpenBao chart creates. The KSA is
    # plain `openbao` in namespace `openbao` because the composition sets
    # fullnameOverride: openbao — verified live (kubectl get sa -n openbao).
    #
    # Unconditioned, deliberately. velero-setup proved on 2026-09-01 that the
    # providerId IAM condition never matches on this cluster, so a conditioned
    # binding here would only reproduce the "denied getAccessToken" failure. Same
    # identity-sameness caveat as Velero: any cluster in this project running a
    # pod as openbao/openbao can use this key. Acceptable while ttf-cluster is
    # the only cluster; revisit before a second one exists.
    echo "🔗 Binding openbao/openbao to ${SEAL_SA}..."
    retry_gcloud gcloud iam service-accounts add-iam-policy-binding "$SEAL_SA" \
        --project="$GCP_PROJECT" \
        --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[openbao/openbao]" \
        --condition=None >/dev/null

    echo ""
    echo "✅ OpenBao KMS seal ready."
    echo ""
    echo "Next, on an ALREADY-INITIALIZED OpenBao (this cluster), the seal must be"
    echo "migrated once with two Shamir shares — see nidavellir docs/secrets-management.md"
    echo "→ 'Migrating to auto-unseal'. On a fresh cluster, init as usual; the seal is"
    echo "picked up automatically and the init output holds RECOVERY keys, not unseal keys."
    ;;

openbao-backup-setup)
    # One-time GCS + IAM + HMAC setup for the OpenBao snapshot agent (realm
    # go-live design, 2026-09-16). The openbao-helm chart's CronJob
    # `openbao-snapshot` saves a Raft snapshot and uploads it with s3cmd, which
    # speaks only S3 — so GCS is reached over its S3-interop endpoint
    # (storage.googleapis.com) with an HMAC key, the shape Mimir's MySQL backups
    # already use and document. Not keyless: Workload Identity cannot issue an
    # HMAC key. Blast radius is bounded the same way as MySQL's: the GSA holds
    # objectAdmin on this one bucket and nothing else.
    #
    # A separate, idempotent action like velero-setup. The HMAC key is minted
    # ONCE, when the Secret is absent; re-runs leave an existing Secret alone,
    # since the secret half of a key is shown only at creation.
    #
    # Bucket name NOT overridable: the nidavellir openbao composition derives it
    # from cluster-identity's gcpProject (<project>-openbao-backups). One
    # derivation. The bucket's region is cluster-identity's gcpRegion, read from
    # the same manifest openbao-seal-setup reads.
    IDENTITY_MANIFEST="$(dirname "$0")/platform/fundamentals/manifests/cluster-identity-gke.yaml"
    BACKUP_REGION="$(sed -n 's/^  gcpRegion:[[:space:]]*//p' "$IDENTITY_MANIFEST")"
    if [[ -z "$BACKUP_REGION" ]]; then
        echo "❌ Could not read gcpRegion from $IDENTITY_MANIFEST." >&2
        exit 1
    fi
    BACKUP_BUCKET="${GCP_PROJECT}-openbao-backups"
    BACKUP_SA_ID="openbao-backup"
    BACKUP_SA="${BACKUP_SA_ID}@${GCP_PROJECT}.iam.gserviceaccount.com"
    BACKUP_SECRET_NS="openbao"
    BACKUP_SECRET="openbao-backup-s3"
    BACKUP_RETENTION_DAYS=30

    echo ""
    echo "🪣 Setting up OpenBao snapshot storage..."
    echo "   Bucket:          gs://${BACKUP_BUCKET} (${BACKUP_REGION})"
    echo "   Service account: ${BACKUP_SA}"
    echo "   Secret:          ${BACKUP_SECRET_NS}/${BACKUP_SECRET}"
    echo ""

    echo "🪣 Creating bucket (skipped if it already exists)..."
    if BACKUP_BUCKET_LOCATION="$(gcloud storage buckets describe "gs://${BACKUP_BUCKET}" --project="$GCP_PROJECT" --format='value(location)' 2>/dev/null)"; then
        # A bucket's location is fixed at creation, so an existing bucket
        # somewhere else is a name collision, not something to reconcile.
        if [[ "${BACKUP_BUCKET_LOCATION,,}" != "${BACKUP_REGION,,}" ]]; then
            echo "❌ gs://${BACKUP_BUCKET} already exists in ${BACKUP_BUCKET_LOCATION}, not ${BACKUP_REGION} (cluster-identity gcpRegion)." >&2
            echo "   The composition derives the bucket name from the project, so this bucket must be the one it uploads to; move or remove it before re-running." >&2
            exit 1
        fi
        echo "   ✅ Bucket already exists in ${BACKUP_BUCKET_LOCATION}."
    else
        gcloud storage buckets create "gs://${BACKUP_BUCKET}" \
            --project="$GCP_PROJECT" \
            --location="$BACKUP_REGION" \
            --uniform-bucket-level-access
        echo "   ✅ Bucket created."
    fi
    # Reconciled on every run, like the lifecycle rule below: a pre-existing
    # bucket with legacy object ACLs would bypass the IAM-only grant.
    gcloud storage buckets update "gs://${BACKUP_BUCKET}" --project="$GCP_PROJECT" \
        --uniform-bucket-level-access >/dev/null

    # The agent expires objects itself (S3_EXPIRE_DAYS, same number); the
    # lifecycle rule is the backstop for an agent that stops running. Applied
    # on every run so the number here is the source of truth.
    echo "🗓️  Setting a ${BACKUP_RETENTION_DAYS}-day lifecycle rule..."
    BACKUP_LIFECYCLE="$(mktemp)"
    printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":%d}}]}\n' "$BACKUP_RETENTION_DAYS" > "$BACKUP_LIFECYCLE"
    gcloud storage buckets update "gs://${BACKUP_BUCKET}" --project="$GCP_PROJECT" \
        --lifecycle-file="$BACKUP_LIFECYCLE" >/dev/null
    rm -f "$BACKUP_LIFECYCLE"
    echo "   ✅ Lifecycle rule set."

    echo "👤 Ensuring service account (skipped if it already exists)..."
    if gcloud iam service-accounts describe "$BACKUP_SA" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Service account already exists."
    else
        gcloud iam service-accounts create "$BACKUP_SA_ID" \
            --project="$GCP_PROJECT" \
            --display-name "OpenBao Raft snapshot uploads"
        echo "   ✅ Service account created."
        # Same propagation lag velero-setup hit: describe answers before the IAM
        # backends accept the account as a member. Poll a real policy read.
        printf "   ⏳ Waiting for the service account to propagate to IAM"
        for _ in $(seq 1 30); do
            if gcloud iam service-accounts get-iam-policy "$BACKUP_SA" \
                --project="$GCP_PROJECT" >/dev/null 2>&1; then
                printf " ready\n"
                break
            fi
            printf "."
            sleep 2
        done
    fi

    # Create + read, never delete or overwrite: the agent only PUTs a
    # timestamped object (and lists the prefix), retention on gke is the
    # lifecycle rule above alone (the composition leaves S3_EXPIRE_DAYS unset
    # here), so a compromised backup pod cannot erase or replace history.
    # objectCreator lacks overwrite, so an exact-minute name collision fails
    # the Job rather than clobbering — visible, and the right outcome.
    echo "🔐 Granting create and read on the bucket (no delete, no overwrite)..."
    retry_gcloud gcloud storage buckets add-iam-policy-binding "gs://${BACKUP_BUCKET}" \
        --project="$GCP_PROJECT" \
        --member="serviceAccount:${BACKUP_SA}" \
        --role=roles/storage.objectCreator >/dev/null
    retry_gcloud gcloud storage buckets add-iam-policy-binding "gs://${BACKUP_BUCKET}" \
        --project="$GCP_PROJECT" \
        --member="serviceAccount:${BACKUP_SA}" \
        --role=roles/storage.objectViewer >/dev/null

    # The HMAC key goes straight from gcloud's JSON into the Secret through
    # 0600 files in a 0700 directory — never an argument, never a variable —
    # the hygiene lib/openbao.sh follows. The Secret's key names are the
    # chart's contract (s3CredentialsSecret): AWS-shaped names holding Google
    # values, exactly as the MySQL backup Secret does.
    echo "🔑 HMAC key for the snapshot agent..."
    . "$(dirname "$0")/lib/kube-context.sh"
    require_kube_context gke || exit 1
    if kubectl get secret -n "$BACKUP_SECRET_NS" "$BACKUP_SECRET" >/dev/null 2>&1; then
        echo "   ✅ Secret ${BACKUP_SECRET_NS}/${BACKUP_SECRET} already exists — keeping it (the key's secret half is shown only at creation)."
        echo "      To rotate: delete the Secret, deactivate and delete the old key"
        echo "      (gcloud storage hmac list --service-account=${BACKUP_SA}), re-run this action."
    else
        if ! command -v jq >/dev/null 2>&1; then
            echo "❌ jq is required to split the HMAC key into the Secret." >&2
            exit 1
        fi
        # The namespace is ArgoCD's to own once OpenBao is deployed; creating it
        # here (apply, not create) lets this action run before or after.
        kubectl create namespace "$BACKUP_SECRET_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        HMAC_SCRATCH=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/openbao-hmac-XXXXXX")
        if ! ( umask 077; gcloud storage hmac create "$BACKUP_SA" --project="$GCP_PROJECT" --format=json > "$HMAC_SCRATCH/hmac.json" ); then
            echo "❌ gcloud storage hmac create failed. If it reports the key limit, list and deactivate stale keys:" >&2
            echo "     gcloud storage hmac list --service-account=${BACKUP_SA} --project=${GCP_PROJECT}" >&2
            rm -rf "$HMAC_SCRATCH"
            exit 1
        fi
        # `--format=json` wraps the API's HmacKey (metadata.accessId + secret);
        # accept a flattened accessId too, so a gcloud that changes the shape
        # fails the -s check below rather than parking an empty id.
        if ! ( umask 077; set -o pipefail
               jq -er '(.metadata.accessId // .accessId) // empty' "$HMAC_SCRATCH/hmac.json" | tr -d '\r\n' > "$HMAC_SCRATCH/id" \
               && jq -er '.secret // empty' "$HMAC_SCRATCH/hmac.json" | tr -d '\r\n' > "$HMAC_SCRATCH/secret" ) \
           || [[ ! -s "$HMAC_SCRATCH/id" || ! -s "$HMAC_SCRATCH/secret" ]]; then
            echo "❌ Could not read accessId and secret from gcloud's output. The key WAS created; its material is at $HMAC_SCRATCH/hmac.json (0600) — park it by hand or deactivate the key." >&2
            exit 1
        fi
        if ! kubectl create secret generic "$BACKUP_SECRET" -n "$BACKUP_SECRET_NS" \
                --from-file=AWS_ACCESS_KEY_ID="$HMAC_SCRATCH/id" \
                --from-file=AWS_SECRET_ACCESS_KEY="$HMAC_SCRATCH/secret" >/dev/null; then
            echo "❌ Creating Secret ${BACKUP_SECRET_NS}/${BACKUP_SECRET} failed. The key material is at $HMAC_SCRATCH/hmac.json (0600) — park it by hand, then remove the directory." >&2
            exit 1
        fi
        if ! rm -rf "$HMAC_SCRATCH" || [[ -e "$HMAC_SCRATCH" ]]; then
            echo "❌ Could not remove $HMAC_SCRATCH — it holds key material; remove it by hand." >&2
            exit 1
        fi
        echo "   ✅ HMAC key minted and parked in Secret ${BACKUP_SECRET_NS}/${BACKUP_SECRET}."
    fi

    echo ""
    echo "✅ OpenBao snapshot storage ready."
    echo ""
    echo "The CronJob openbao-snapshot (nidavellir's openbao composition) uploads to"
    echo "s3://${BACKUP_BUCKET}/openbao/ at 05:00 UTC daily, once OpenBao has the"
    echo "openbao-backup role (./openbao-configure.sh gke <realm>). Prove it rather than assume:"
    echo "   kubectl create job --from=cronjob/openbao-snapshot -n openbao openbao-snapshot-manual"
    echo "   gcloud storage ls gs://${BACKUP_BUCKET}/openbao/ --project=${GCP_PROJECT}"
    ;;

credentials)
    echo ""
    echo "🔑 Fetching credentials for existing cluster..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE"
    echo "✅ kubectl context: $(kubectl config current-context)"
    ;;

delete)
    echo ""
    echo "🗑️  Deleting cluster $CLUSTER_NAME..."
    echo "   This will permanently destroy all data in the cluster."
    read -r -p "   Confirm cluster name to delete: " CONFIRM
    if [[ "$CONFIRM" != "$CLUSTER_NAME" ]]; then
        echo "❌ Name mismatch. Aborting."
        exit 1
    fi
    gcloud container clusters delete "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE" \
        --quiet
    echo "✅ Cluster deleted."

    # Neither the Velero service account NOR the bucket is deleted here, and both
    # omissions are deliberate.
    #
    # The service account is PROJECT-scoped, not cluster-scoped: the Workload
    # Identity pool is `<project>.svc.id.goog`, so every cluster in this project
    # binds the same `velero/velero` identity. Deleting it on one cluster's
    # teardown would silently break Velero on every other cluster in the project.
    #
    # The bucket holds backups whose entire purpose is outliving the loss of a
    # cluster. Deleting it here would make this command the most destructive
    # thing in the repo.
    echo ""
    echo "ℹ️  Velero and OpenBao backup resources were KEPT — all project-scoped, not cluster-scoped:"
    echo "     gs://${GCP_PROJECT}-velero            (backups outlive clusters)"
    echo "     gs://${GCP_PROJECT}-openbao-backups   (Raft snapshots outlive clusters)"
    echo "     velero@${GCP_PROJECT}.iam.gserviceaccount.com  (shared by all clusters in this project)"
    echo "     openbao-backup@${GCP_PROJECT}.iam.gserviceaccount.com  (and its HMAC key)"
    echo ""
    echo "   Remove them by hand ONLY if no other cluster in this project uses Velero:"
    echo "     gcloud iam service-accounts delete velero@${GCP_PROJECT}.iam.gserviceaccount.com"
    echo "     gcloud iam roles delete velero.server --project=$GCP_PROJECT"
    echo "     gcloud storage rm -r gs://${GCP_PROJECT}-velero   # discards backup history"
    ;;

*)
    echo "Usage: $0 [create|delete|credentials|velero-setup|openbao-seal-setup|openbao-backup-setup]"
    echo ""
    echo "  create        Create the GKE cluster and fetch credentials"
    echo "  credentials   Fetch kubectl credentials for an existing cluster"
    echo "  velero-setup  One-time GCS bucket + IAM for Velero (idempotent;"
    echo "                safe to run against an already-running cluster)"
    echo "  openbao-seal-setup  One-time KMS key + IAM so OpenBao auto-unseals (idempotent)"
    echo "  openbao-backup-setup  One-time GCS bucket + GSA + HMAC key Secret for the"
    echo "                OpenBao snapshot agent (idempotent; the key is minted once)"
    echo "  delete        Delete the cluster (keeps the Velero backup bucket)"
    exit 1
    ;;
esac
