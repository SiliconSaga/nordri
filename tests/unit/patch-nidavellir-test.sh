#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/patch-nidavellir.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

# Arrange: a fake hydrated tree carrying the placeholder strings.
tree="$(mktemp -d)"; trap 'rm -rf "$tree"' EXIT
mkdir -p "$tree/apps"
printf 'path: vegvisir/manifests/overlays/homelab\n' > "$tree/apps/vegvisir-app.yaml"
printf 'hostname: tailscale-operator-MACHINE\n'      > "$tree/apps/tailscale-operator-app.yaml"

# Act + assert: homelab target rewrites overlay to homelab and stamps a host name.
out="$(patch_nidavellir_tree "$tree" homelab)"; rc=$?
check "homelab returns 0" "[ $rc -eq 0 ]"
check "vegvisir overlay stays homelab" "grep -q 'overlays/homelab' '$tree/apps/vegvisir-app.yaml'"
check "tailscale hostname stamped (not literal MACHINE)" "! grep -q 'tailscale-operator-MACHINE' '$tree/apps/tailscale-operator-app.yaml'"

# gke target rewrites overlay to gke and uses the fixed gke hostname.
printf 'path: vegvisir/manifests/overlays/homelab\n' > "$tree/apps/vegvisir-app.yaml"
printf 'hostname: tailscale-operator-MACHINE\n'      > "$tree/apps/tailscale-operator-app.yaml"
patch_nidavellir_tree "$tree" gke >/dev/null
check "gke overlay rewritten" "grep -q 'overlays/gke' '$tree/apps/vegvisir-app.yaml'"
check "gke hostname is tailscale-operator-gke" "grep -q 'tailscale-operator-gke' '$tree/apps/tailscale-operator-app.yaml'"

# Renamed placeholder must fail loudly (verification catches a no-op sed).
printf 'path: vegvisir/manifests/overlays/RENAMED\n' > "$tree/apps/vegvisir-app.yaml"
printf 'hostname: tailscale-operator-MACHINE\n'      > "$tree/apps/tailscale-operator-app.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "renamed vegvisir placeholder returns non-zero" "[ $rc -ne 0 ]"

# Missing file must fail loudly.
rm -f "$tree/apps/vegvisir-app.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "missing manifest returns non-zero" "[ $rc -ne 0 ]"

# Empty/unknown target must fail fast (not silently corrupt the overlay path).
printf 'path: vegvisir/manifests/overlays/homelab\n' > "$tree/apps/vegvisir-app.yaml"
printf 'hostname: tailscale-operator-MACHINE\n'      > "$tree/apps/tailscale-operator-app.yaml"
patch_nidavellir_tree "$tree" "" >/dev/null 2>&1; rc=$?
check "empty target returns non-zero" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
