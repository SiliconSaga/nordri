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
    echo "Next: run ./bootstrap.sh gke"
    echo ""
    echo "⚠️  Remember: this cluster costs money. Delete it when done:"
    echo "   ./scripts/gke-provision.sh delete"
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
    ;;

*)
    echo "Usage: $0 [create|delete|credentials]"
    exit 1
    ;;
esac
