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
#   ./scripts/gke-provision.sh [create|delete|credentials]
#
# After creating the cluster:
#   ./bootstrap.sh gke
#
# To start over with a clean cluster (recommended over fighting finalizers):
#   ./scripts/gke-provision.sh delete   # then re-run create
#
# After testing:
#   ./scripts/gke-provision.sh delete

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
    echo "   ./scripts/gke-provision.sh delete"
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
    fi

    # Object access is scoped to the one bucket rather than project-wide.
    echo "🔐 Granting object access on the bucket..."
    gcloud storage buckets add-iam-policy-binding "gs://${VELERO_BUCKET}" \
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
    gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
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
    # The WI pool is PROJECT-level: the member `<project>.svc.id.goog[velero/velero]`
    # matches a `velero/velero` ServiceAccount in EVERY cluster in the project.
    # GKE calls this identity sameness, and unconditioned it means any cluster
    # here that happens to run a pod as velero/velero can impersonate this
    # account and read or write the whole backup bucket.
    #
    # The IAM condition pins the binding to one cluster by its provider id, so
    # the KSA name can stay `velero/velero` (no manifest change, no per-cluster
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
    echo "🔗 Binding velero/velero to $VELERO_SA, scoped to $CLUSTER_NAME..."
    gcloud iam service-accounts add-iam-policy-binding "$VELERO_SA" \
        --project="$GCP_PROJECT" \
        --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]" \
        --condition="expression=request.auth.claims.google.providerId=='${VELERO_WI_PROVIDER}',title=restrict-to-${CLUSTER_NAME}" >/dev/null

    # An earlier run of this script created the same binding WITHOUT a condition.
    # That unconditioned binding still grants every cluster in the project, and
    # IAM evaluates bindings as a union — so leaving it in place makes the
    # condition above decorative. Report it rather than removing it silently.
    # Match the EXACT principal, not just the role. The earlier filter keyed on
    # role plus "condition title does not contain restrict-to-", which would also
    # match some other member, or another cluster's differently-titled condition,
    # and then print a removal command for a binding that does not exist.
    #
    # gcloud's filter language cannot express "this member AND no condition at
    # all", so the policy is read as JSON and matched with jq. jq is optional
    # here: the check is advisory, so a machine without it gets a note rather
    # than a failure.
    VELERO_WI_MEMBER="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]"
    if ! command -v jq >/dev/null 2>&1; then
        echo "ℹ️  jq not found — skipping the check for a leftover unconditioned binding."
        echo "   Inspect manually: gcloud iam service-accounts get-iam-policy $VELERO_SA"
    elif gcloud iam service-accounts get-iam-policy "$VELERO_SA" \
        --project="$GCP_PROJECT" --format=json 2>/dev/null \
        | jq -e --arg m "$VELERO_WI_MEMBER" '
            .bindings // []
            | map(select(
                .role == "roles/iam.workloadIdentityUser"
                and (has("condition") | not)
                and (.members // [] | index($m))
              ))
            | length > 0' >/dev/null; then
        echo "⚠️  An UNCONDITIONED workloadIdentityUser binding still exists on ${VELERO_SA}."
        echo "   IAM unions bindings, so it grants every cluster in the project and"
        echo "   makes the cluster-scoped condition above ineffective. Remove it:"
        echo "     gcloud iam service-accounts remove-iam-policy-binding $VELERO_SA \\"
        echo "       --project=$GCP_PROJECT --role=roles/iam.workloadIdentityUser \\"
        echo "       --member='serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]' \\"
        echo "       --condition=None"
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
    echo "ℹ️  Velero resources were KEPT — both are project-scoped, not cluster-scoped:"
    echo "     gs://${GCP_PROJECT}-velero            (backups outlive clusters)"
    echo "     velero@${GCP_PROJECT}.iam.gserviceaccount.com  (shared by all clusters in this project)"
    echo ""
    echo "   Remove them by hand ONLY if no other cluster in this project uses Velero:"
    echo "     gcloud iam service-accounts delete velero@${GCP_PROJECT}.iam.gserviceaccount.com"
    echo "     gcloud iam roles delete velero.server --project=$GCP_PROJECT"
    echo "     gcloud storage rm -r gs://${GCP_PROJECT}-velero   # discards backup history"
    ;;

*)
    echo "Usage: $0 [create|delete|credentials|velero-setup]"
    echo ""
    echo "  create        Create the GKE cluster and fetch credentials"
    echo "  credentials   Fetch kubectl credentials for an existing cluster"
    echo "  velero-setup  One-time GCS bucket + IAM for Velero (idempotent;"
    echo "                safe to run against an already-running cluster)"
    echo "  delete        Delete the cluster (keeps the Velero backup bucket)"
    exit 1
    ;;
esac
