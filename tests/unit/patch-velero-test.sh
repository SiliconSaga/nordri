#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/patch-velero.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

tree="$(mktemp -d)"; trap 'rm -rf "$tree"' EXIT
mkdir -p "$tree/platform/fundamentals/apps" "$tree/platform/fundamentals/manifests"
printf 'bucket: __GCP_PROJECT__-velero\n' > "$tree/platform/fundamentals/apps/velero-gke.yaml"
printf 'data:\n  gcpProject: __GCP_PROJECT__\n' > "$tree/platform/fundamentals/manifests/cluster-identity-gke.yaml"

# gke: both files stamped with the env-provided project.
GCP_PROJECT=example-proj-1 patch_velero_tree "$tree" gke >/dev/null; rc=$?
check "gke returns 0" "[ $rc -eq 0 ]"
check "velero app stamped" "grep -q 'example-proj-1-velero' '$tree/platform/fundamentals/apps/velero-gke.yaml'"
check "cluster-identity stamped" "grep -q 'gcpProject: example-proj-1' '$tree/platform/fundamentals/manifests/cluster-identity-gke.yaml'"
check "no placeholder survives" "! grep -rq '__GCP_PROJECT__' '$tree'"

# homelab: no-op, files untouched.
printf 'data:\n  gcpProject: __GCP_PROJECT__\n' > "$tree/platform/fundamentals/manifests/cluster-identity-gke.yaml"
patch_velero_tree "$tree" homelab >/dev/null; rc=$?
check "homelab returns 0" "[ $rc -eq 0 ]"
check "homelab leaves placeholder alone" "grep -q '__GCP_PROJECT__' '$tree/platform/fundamentals/manifests/cluster-identity-gke.yaml'"

# gke with cluster-identity missing must fail loudly.
rm -f "$tree/platform/fundamentals/manifests/cluster-identity-gke.yaml"
GCP_PROJECT=example-proj-1 patch_velero_tree "$tree" gke >/dev/null 2>&1; rc=$?
check "missing cluster-identity returns non-zero" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
