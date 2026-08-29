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

CLUSTER_NAME="${GKE_CLUSTER_NAME:-nordri-test}"
GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
GCP_ZONE="${GCP_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
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
    VELERO_BUCKET="${VELERO_BUCKET:-${GCP_PROJECT}-velero}"
    VELERO_SA="velero@${GCP_PROJECT}.iam.gserviceaccount.com"

    echo ""
    echo "🪣 Setting up Velero backup storage..."
    echo "   Bucket:          gs://${VELERO_BUCKET}"
    echo "   Service account: ${VELERO_SA}"
    echo ""

    # Workload Identity must be on for the SA binding to mean anything. Without
    # it the binding is accepted and simply never used, and Velero fails to
    # authenticate at backup time rather than at install time — a silent gap.
    echo "🔍 Verifying Workload Identity is enabled on $CLUSTER_NAME..."
    WI_POOL="$(gcloud container clusters describe "$CLUSTER_NAME" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --format='value(workloadIdentityConfig.workloadPool)' 2>/dev/null || true)"
    if [[ -z "$WI_POOL" ]]; then
        echo "❌ Workload Identity is not enabled on cluster '$CLUSTER_NAME'."
        echo "   Velero on GKE authenticates through it. Enable with:"
        echo "     gcloud container clusters update $CLUSTER_NAME \\"
        echo "       --project=$GCP_PROJECT --zone=$GCP_ZONE \\"
        echo "       --workload-pool=${GCP_PROJECT}.svc.id.goog"
        exit 1
    fi
    echo "   ✅ Workload pool: $WI_POOL"

    echo "🪣 Creating bucket (skipped if it already exists)..."
    if gcloud storage buckets describe "gs://${VELERO_BUCKET}" --project="$GCP_PROJECT" >/dev/null 2>&1; then
        echo "   ✅ Bucket already exists."
    else
        gcloud storage buckets create "gs://${VELERO_BUCKET}" \
            --project="$GCP_PROJECT" \
            --location="$GCP_ZONE" \
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

    # Disk snapshots are inherently project-scoped; there is no per-disk role.
    echo "🔐 Granting persistent-disk snapshot access (project-scoped)..."
    gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
        --member="serviceAccount:${VELERO_SA}" \
        --role=roles/compute.storageAdmin \
        --condition=None >/dev/null

    echo "🔗 Binding the Kubernetes SA velero/velero to $VELERO_SA..."
    gcloud iam service-accounts add-iam-policy-binding "$VELERO_SA" \
        --project="$GCP_PROJECT" \
        --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[velero/velero]" >/dev/null

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

    # The Velero service account is cluster-scoped in practice (its Workload
    # Identity binding names this cluster's pool), so it goes with the cluster.
    echo "🧹 Removing the Velero service account..."
    gcloud iam service-accounts delete "velero@${GCP_PROJECT}.iam.gserviceaccount.com" \
        --project="$GCP_PROJECT" --quiet 2>/dev/null || true

    # The BUCKET is deliberately kept. Backups whose only purpose is surviving the
    # loss of a cluster must not be deleted along with it — that would make this
    # command the single most destructive thing in the repo. Delete it by hand if
    # you genuinely mean to discard backup history:
    #   gcloud storage rm -r gs://${GCP_PROJECT}-velero
    echo "ℹ️  Backup bucket gs://${GCP_PROJECT}-velero was KEPT (backups outlive clusters)."
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
