#!/bin/bash
# nordri/openbao-init.sh — initialize OpenBao once, with the init material
# handed to the operator for the password safe.
#
# Usage:
#   ./openbao-init.sh <gke|homelab> <output-file>
#
# What it does, in order (all via lib/openbao.sh, the same code bootstrap's
# Layer 5b runs):
#   1. refuses unless kubectl's current context fits the target
#      (lib/kube-context.sh — the ws k8s guard scope does not switch contexts)
#   2. waits for the OpenBao pod to answer `bao status`
#   3. refuses an instance that is already initialized: init material can be
#      minted exactly once, and this script never prints or re-reads it
#   4. `bao operator init` (3 shares, threshold 2); the JSON is parked in
#      Secret openbao/openbao-init (init.json + root_token) and, once that
#      Secret reads back, ALSO copied to <output-file> (0600)
#   5. unseals a Shamir instance from the parked shares; under seal: auto the
#      instance unseals itself and the shares are recovery keys
#   6. prints `bao status` — never the material
#
# The operator then moves <output-file>'s contents into the password safe and
# deletes the file. Custody is realm ADR 0002's in-cluster posture plus that
# safe (realm docs/plans/2026-09-16-openbao-go-live-design.md): two copies in
# two failure domains. Configure and seed next with ./openbao-configure.sh.
#
# Environment: OPENBAO_NS, OPENBAO_POD, OPENBAO_INIT_SECRET as in lib/openbao.sh;
# KUBE_CONTEXT as in lib/kube-context.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/openbao.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"

TARGET="${1:-}"
OUT="${2:-}"

usage() {
    echo "Usage: ./openbao-init.sh <gke|homelab> <output-file>" >&2
    echo "   <output-file> receives the init JSON (0600) for the password safe; it must not exist yet." >&2
}

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "❌ Target must be 'gke' or 'homelab'." >&2
    usage
    exit 1
fi
if [[ -z "$OUT" ]]; then
    echo "❌ An output file for the init material is required." >&2
    usage
    exit 1
fi
if [[ -e "$OUT" ]]; then
    echo "❌ $OUT already exists. This script never overwrites: if it holds an earlier run's material, move that into the safe first; otherwise pick another path." >&2
    exit 1
fi
OUT_DIR="$(dirname "$OUT")"
if [[ ! -d "$OUT_DIR" || ! -w "$OUT_DIR" ]]; then
    echo "❌ Cannot write into $OUT_DIR (missing or not writable). Choose a directory you own, e.g. your home directory." >&2
    exit 1
fi

require_kube_context "$TARGET" || exit 1

echo "⏳ Waiting for $OPENBAO_NS/$OPENBAO_POD to answer bao status..."
openbao_wait_running 600 || exit 1

if [[ "$(openbao_status_field '.initialized')" == "true" ]]; then
    echo "❌ OpenBao on $TARGET is already initialized; init material cannot be minted again." >&2
    echo "   Existing custody: Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET (if bootstrap or an earlier run parked it)." >&2
    echo "   For a genuinely fresh start, wipe the instance first (delete the pod and its PVC — the go-live design's sequence), then re-run." >&2
    exit 2
fi

echo "🔐 Initializing OpenBao on $TARGET..."
OPENBAO_INIT_KEEP_FILE="$OUT"
openbao_ensure_initialized || exit 1
openbao_ensure_unsealed || exit 1

echo ""
echo "📋 bao status:"
kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- bao status || true
echo ""
echo "✅ Initialized. Now:"
echo "   1. Move the contents of $OUT into the password safe (all shares and the root token)."
echo "   2. Delete the file:  rm $OUT"
echo "   3. Configure and seed:  ./openbao-configure.sh $TARGET [realm]"
