#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/patch-nidavellir.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

# Arrange: a fake hydrated tree carrying the placeholder strings.
# Bail rather than carry an empty $tree: every path below is "$tree/...", so an
# empty one aims the teardown's `rm -rf` at the filesystem root.
tree="$(mktemp -d)" || { echo "NOT OK - could not create a temp dir" >&2; exit 1; }
[ -n "$tree" ] && [ -d "$tree" ] || { echo "NOT OK - temp dir is not usable" >&2; exit 1; }
trap 'rm -rf "$tree"' EXIT
seed_tree() {
    mkdir -p "$tree/apps" "$tree/ntfy"
    printf 'path: vegvisir/manifests/overlays/homelab\n' > "$tree/apps/vegvisir-app.yaml"
    printf 'hostname: tailscale-operator-MACHINE\n'      > "$tree/apps/tailscale-operator-app.yaml"
    printf 'tailscaleHostname: ntfy-MACHINE\nbaseUrl: "http://ntfy-MACHINE.tailf5b47a.ts.net"\n' \
        > "$tree/ntfy/claim.yaml"
}
seed_tree

# Act + assert: homelab target rewrites overlay to homelab and stamps a host name.
out="$(patch_nidavellir_tree "$tree" homelab)"; rc=$?
check "homelab returns 0" "[ $rc -eq 0 ]"
check "vegvisir overlay stays homelab" "grep -q 'overlays/homelab' '$tree/apps/vegvisir-app.yaml'"
check "tailscale hostname stamped (not literal MACHINE)" "! grep -q 'tailscale-operator-MACHINE' '$tree/apps/tailscale-operator-app.yaml'"
check "homelab ntfy hostname stamped" "! grep -q 'ntfy-MACHINE' '$tree/ntfy/claim.yaml'"
# ⚠ A homelab box must NOT claim GKE's ntfy device name. That is what the
# hardcoded claim did, and two clusters sharing one MagicDNS name would route a
# box's alerts to the wrong phone.
check "homelab ntfy is not ntfy-gke" "! grep -q 'ntfy-gke' '$tree/ntfy/claim.yaml'"
check "homelab ntfy hostname matches its base-url" "[ \"\$(grep -c \"\$(sed -n 's/^tailscaleHostname: //p' '$tree/ntfy/claim.yaml')\" '$tree/ntfy/claim.yaml')\" -eq 2 ]"

# gke target rewrites overlay to gke and uses the fixed gke hostnames.
seed_tree
patch_nidavellir_tree "$tree" gke >/dev/null
check "gke overlay rewritten" "grep -q 'overlays/gke' '$tree/apps/vegvisir-app.yaml'"
check "gke hostname is tailscale-operator-gke" "grep -q 'tailscale-operator-gke' '$tree/apps/tailscale-operator-app.yaml'"
check "gke ntfy hostname is ntfy-gke" "grep -q 'tailscaleHostname: ntfy-gke' '$tree/ntfy/claim.yaml'"
check "gke ntfy base-url matches" "grep -q 'http://ntfy-gke.tailf5b47a.ts.net' '$tree/ntfy/claim.yaml'"

# Renamed placeholder must fail loudly (verification catches a no-op sed).
seed_tree
printf 'path: vegvisir/manifests/overlays/RENAMED\n' > "$tree/apps/vegvisir-app.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "renamed vegvisir placeholder returns non-zero" "[ $rc -ne 0 ]"

# A renamed ntfy placeholder must fail too, rather than shipping a claim that
# asks for a device name no cluster meant to own.
seed_tree
printf 'tailscaleHostname: ntfy-RENAMED\n' > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "renamed ntfy placeholder returns non-zero" "[ $rc -ne 0 ]"

# A placeholder surviving in only ONE of the two ntfy fields is the dangerous
# half-stamp: the device name and the advertised URL would disagree.
seed_tree
printf 'tailscaleHostname: ntfy-MACHINE\nbaseUrl: "http://ntfy-MACHINE.ts.net"\nstray: ntfy-MACHINE\n' \
    > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "all ntfy placeholders are stamped, not just the first" "! grep -q 'ntfy-MACHINE' '$tree/ntfy/claim.yaml'"

# Each ntfy field must carry the stamped name: a placeholder-free baseUrl that
# points elsewhere must not pass on the strength of the hostname alone.
seed_tree
printf 'tailscaleHostname: ntfy-MACHINE\nbaseUrl: "http://ntfy-elsewhere.tailf5b47a.ts.net"\n' \
    > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "a baseUrl that disagrees with the hostname returns non-zero" "[ $rc -ne 0 ]"
seed_tree
printf 'tailscaleHostname: ntfy-elsewhere\nbaseUrl: "http://ntfy-MACHINE.tailf5b47a.ts.net"\n' \
    > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "a hostname that disagrees with the baseUrl returns non-zero" "[ $rc -ne 0 ]"

# The real claim is indented under spec.parameters; the field checks must
# still find it there.
seed_tree
printf 'spec:\n  parameters:\n    tailscaleHostname: ntfy-MACHINE\n    baseUrl: "http://ntfy-MACHINE.tailf5b47a.ts.net"\n' \
    > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "an indented claim is stamped and passes" "[ $rc -eq 0 ]"

# The real claim's comments mention ntfy-gke while explaining the history; a
# comment is not a stale claim.
seed_tree
printf '# These were hardcoded to ntfy-gke before.\ntailscaleHostname: ntfy-MACHINE\nbaseUrl: "http://ntfy-MACHINE.tailf5b47a.ts.net"\n' \
    > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "ntfy-gke in a comment is not a stale claim" "[ $rc -eq 0 ]"

# A nidavellir checkout from before the placeholder hardcodes ntfy-gke. Homelab
# must refuse it; GKE accepts it, since ntfy-gke is GKE's own name.
seed_tree
printf 'tailscaleHostname: ntfy-gke\nbaseUrl: "http://ntfy-gke.tailf5b47a.ts.net"\n' > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab > /dev/null 2> "$tree/stale.err"; rc=$?
check "a stale ntfy-gke claim on homelab returns non-zero" "[ $rc -ne 0 ]"
check "the stale-claim failure says to update nidavellir" "grep -q 'predates the ntfy-MACHINE placeholder' '$tree/stale.err'"
seed_tree
printf 'tailscaleHostname: ntfy-gke\nbaseUrl: "http://ntfy-gke.tailf5b47a.ts.net"\n' > "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" gke >/dev/null 2>&1; rc=$?
check "a stale ntfy-gke claim on gke still passes" "[ $rc -eq 0 ]"

# Missing file must fail loudly.
seed_tree
rm -f "$tree/apps/vegvisir-app.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "missing manifest returns non-zero" "[ $rc -ne 0 ]"

# A missing ntfy claim must fail loudly rather than with a bare sed error.
seed_tree
rm -f "$tree/ntfy/claim.yaml"
patch_nidavellir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "missing ntfy claim returns non-zero" "[ $rc -ne 0 ]"

# Empty/unknown target must fail fast (not silently corrupt the overlay path).
seed_tree
patch_nidavellir_tree "$tree" "" >/dev/null 2>&1; rc=$?
check "empty target returns non-zero" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
