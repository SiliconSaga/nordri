# components/nordri/lib/patch-nidavellir.sh
# Per-target patching of a hydrated nidavellir tree. Sourced by bootstrap.sh
# and update-embedded-git.sh. Returns non-zero on any failure (caller decides
# whether to exit). Echoes the resolved tailscale hostname on success.
#
# Two cluster-specific rewrites:
#   1. Point the vegvisir app at the env overlay so the LetsEncrypt issuers +
#      the *.cmdbee.org wildcard cert only land on GKE; homelab keeps the
#      self-signed Gateway cert so its websecure listener programs.
#   2. Stamp the tailscale operator hostname. GKE is a single shared cluster,
#      so it gets a stable `tailscale-operator-gke`; each homelab cluster is
#      per-machine (one cluster per box) so it gets `tailscale-operator-<machine>`
#      to avoid tailnet device-name collisions. The workstation name is a valid
#      identity only for homelab — deriving it on GKE would churn the device
#      name between hydrations run from different machines.
patch_nidavellir_tree() {
    local tree="$1" target="$2"
    local vegvisir_app="$tree/apps/vegvisir-app.yaml"
    local tailscale_app="$tree/apps/tailscale-operator-app.yaml"
    local ntfy_claim="$tree/ntfy/claim.yaml"
    local f ts_hostname ntfy_hostname node machine
    # Validate the caller-supplied target before any sed: an empty/unknown target
    # would rewrite `overlays/homelab` → `overlays/<bad>` AND still pass the later
    # verification (which greps the same substituted value), silently corrupting
    # the manifest path.
    case "$target" in
        homelab|gke) ;;
        *)
            echo "❌ patch_nidavellir_tree: unknown target '$target' (expected homelab|gke)." >&2
            return 1
            ;;
    esac
    # Guard: these apps must exist in the hydrated tree; a missing path (e.g. a
    # nidavellir apps/ rename) would otherwise abort with a bare `sed` error.
    for f in "$vegvisir_app" "$tailscale_app" "$ntfy_claim"; do
        if [[ ! -f "$f" ]]; then
            echo "❌ Expected nidavellir manifest missing: ${f#"$tree"/} — has apps/ been renamed?" >&2
            return 1
        fi
    done
    # One identity, two device names derived from it. ntfy is stamped from the
    # same value as the operator so a cluster's tailnet devices agree about which
    # box they belong to — ntfy's claim previously hardcoded `ntfy-gke`, so every
    # homelab cluster was requesting GKE's device name.
    if [[ "$target" == "gke" ]]; then
        node="gke"
    else
        machine="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname)"
        machine="$(printf '%s' "$machine" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
        [[ -z "$machine" ]] && machine="local"
        # A box that happens to be named gke would claim GKE's device names.
        # Refuse before any sed, so the tree is left as it was.
        if [[ "$machine" == "gke" ]]; then
            echo "❌ This machine's name normalizes to 'gke', which is reserved for the GKE cluster's tailnet devices. Rename the machine or hydrate from another box." >&2
            return 1
        fi
        node="$machine"
    fi
    ts_hostname="tailscale-operator-$node"
    ntfy_hostname="ntfy-$node"
    # Portable sed -i (BSD/macOS needs '' as the backup extension, GNU/MSYS must not).
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|path: vegvisir/manifests/overlays/homelab|path: vegvisir/manifests/overlays/$target|g" "$vegvisir_app"
        sed -i '' "s|tailscale-operator-MACHINE|$ts_hostname|g" "$tailscale_app"
        sed -i '' "s|ntfy-MACHINE|$ntfy_hostname|g" "$ntfy_claim"
    else
        sed -i "s|path: vegvisir/manifests/overlays/homelab|path: vegvisir/manifests/overlays/$target|g" "$vegvisir_app"
        sed -i "s|tailscale-operator-MACHINE|$ts_hostname|g" "$tailscale_app"
        sed -i "s|ntfy-MACHINE|$ntfy_hostname|g" "$ntfy_claim"
    fi
    # Verify the substitutions took effect — sed exits 0 even when nothing
    # matched, so a renamed placeholder upstream would silently push the wrong
    # overlay path / an unstamped hostname (the exact failure modes this prevents).
    if ! grep -q "path: vegvisir/manifests/overlays/$target" "$vegvisir_app"; then
        echo "❌ vegvisir overlay path not patched — the 'overlays/homelab' placeholder may have changed." >&2
        return 1
    fi
    if ! grep -q "$ts_hostname" "$tailscale_app"; then
        echo "❌ tailscale operator hostname not stamped — the 'tailscale-operator-MACHINE' placeholder may have changed." >&2
        return 1
    fi
    # Both the hostname and the base-url carry the placeholder, so a leftover is
    # a mismatch between the device name ntfy claims and the URL it advertises.
    if grep -q "ntfy-MACHINE" "$ntfy_claim"; then
        echo "❌ ntfy hostname not stamped — an 'ntfy-MACHINE' placeholder survived in ntfy/claim.yaml." >&2
        return 1
    fi
    # A nidavellir checkout from before the placeholder still hardcodes ntfy-gke.
    # That is right for GKE and wrong everywhere else, so homelab refuses it
    # rather than claiming GKE's device name.
    if [[ "$target" != "gke" ]] && grep -Eq '^[[:space:]]*tailscaleHostname:[[:space:]]*"?ntfy-gke"?[[:space:]]*$' "$ntfy_claim"; then
        echo "❌ ntfy/claim.yaml hardcodes ntfy-gke: this nidavellir checkout predates the ntfy-MACHINE placeholder. Update nidavellir and re-run." >&2
        return 1
    fi
    # Each field is checked on its own: a match in one must not cover for the
    # other, or the device name and the advertised URL could disagree.
    if ! grep -Eq "^[[:space:]]*tailscaleHostname:[[:space:]]*\"?$ntfy_hostname\"?[[:space:]]*$" "$ntfy_claim"; then
        echo "❌ ntfy tailscaleHostname is not $ntfy_hostname — the 'ntfy-MACHINE' placeholder may have changed." >&2
        return 1
    fi
    # The whole URL, not just its first label: ntfy is reachable only through
    # MagicDNS, so the host must end in a tailnet's .ts.net domain.
    if ! grep -Eq "^[[:space:]]*baseUrl:[[:space:]]*\"?https?://$ntfy_hostname\.[a-z0-9-]+\.ts\.net/?\"?[[:space:]]*$" "$ntfy_claim"; then
        echo "❌ ntfy baseUrl does not point at $ntfy_hostname — the 'ntfy-MACHINE' placeholder may have changed." >&2
        return 1
    fi
    printf '%s' "$ts_hostname"
}
