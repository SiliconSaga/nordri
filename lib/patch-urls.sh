# components/nordri/lib/patch-urls.sh
# Target-specific repoURL rewrite for hydrated trees. Sourced by bootstrap.sh
# and update-embedded-git.sh; lib/hydrate.sh calls patch_repo_urls_tree and
# relies on the caller having sourced this file first.
#
# Git carries the DURABLE form of every ArgoCD repoURL — the in-cluster Forgejo
# host — because after the Forgejo cutover Forgejo's main is GitHub's main
# verbatim, and a committed seed URL would be pulled straight back over the
# cutover. The seed Gitea only ever sees a hydrated copy, so the seed form is
# applied here, at hydration, the same way overlay paths and the GCP project
# are stamped. See realm-siliconsaga docs/plans/2026-09-07-forgejo-day2-design.md.
#
# Modes:
#   seed     rewrite Forgejo URLs -> seed URLs (bootstrap, day-2 seed hydration)
#   forgejo  leave the tree alone (hydration into Forgejo)
#   swap     leave the tree alone (the cutover commit pushed INTO the seed, which
#            must point ArgoCD at Forgejo — the only seed hydration without the
#            rewrite; distinct from `forgejo` so callers say what they mean)
#
# These two literals are the ONLY place either host lives in nordri's scripts.
FORGEJO_GIT_BASE_URL="http://forgejo-http.forgejo.svc.cluster.local:3000/siliconsaga"
SEED_GIT_BASE_URL="http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin"

# The URLs are matched LITERALLY everywhere: grep with -F, and sed with the
# regex metacharacters escaped (the dots in the hostnames would otherwise match
# any character, so a near-miss host would be rewritten too). `|` is the sed
# delimiter and does not occur in either URL.
_patch_repo_urls_sed_escape() { printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'; }
FORGEJO_GIT_BASE_URL_RE="$(_patch_repo_urls_sed_escape "$FORGEJO_GIT_BASE_URL")"

# _patch_repo_urls_check_mode <mode>: 0 for a known mode, 1 otherwise.
_patch_repo_urls_check_mode() {
    case "$1" in
        seed|forgejo|swap) return 0 ;;
        *)
            echo "❌ patch_repo_urls: unknown mode '$1' (expected seed|forgejo|swap)." >&2
            return 1
            ;;
    esac
}

# patch_repo_urls_file <file> <mode> [<label>]
# One manifest. In seed mode rewrites the Forgejo form to the seed form and
# fails closed if any survives. In forgejo/swap mode rewrites nothing but
# REFUSES a file that still carries the seed form: a swap commit with one seed
# URL left in it points ArgoCD back at the seed that is about to be retired,
# silently, so that is an error rather than a warning. Echoes 1 if the file
# was rewritten, else 0. <label> is the path shown in messages (default: file).
patch_repo_urls_file() {
    local f="$1" mode="$2" label="${3:-$1}"
    _patch_repo_urls_check_mode "$mode" || return 1
    if [[ "$mode" != "seed" ]]; then
        # grep's exit status is the signal here, so read all three: 0 = seed
        # URL present (refuse), 1 = clean, anything else = grep could not read
        # the file, which must not pass as "clean".
        local rc=0
        grep -Fq -- "$SEED_GIT_BASE_URL" "$f" || rc=$?
        case "$rc" in
            0)
                echo "❌ patch_repo_urls_file: seed URL present in $label under mode '$mode' — the committed form must be the Forgejo URL." >&2
                return 1
                ;;
            1) ;;
            *)
                echo "❌ patch_repo_urls_file: could not scan $label (grep exit $rc)." >&2
                return 1
                ;;
        esac
        echo 0
        return 0
    fi
    if ! grep -Fq -- "$FORGEJO_GIT_BASE_URL" "$f"; then
        echo 0
        return 0
    fi
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|$FORGEJO_GIT_BASE_URL_RE|$SEED_GIT_BASE_URL|g" "$f" || return 1
    else
        sed -i "s|$FORGEJO_GIT_BASE_URL_RE|$SEED_GIT_BASE_URL|g" "$f" || return 1
    fi
    # Fail closed, as patch-velero does: a Forgejo URL surviving into the
    # seed means ArgoCD would try a host that does not exist yet.
    if grep -Fq -- "$FORGEJO_GIT_BASE_URL" "$f"; then
        echo "❌ patch_repo_urls_file: Forgejo URL survived rewrite in $label." >&2
        return 1
    fi
    echo 1
}

# patch_repo_urls_tree <tree> <mode>
# Every *.yaml under the tree through patch_repo_urls_file; echoes the number
# of files rewritten. Only *.yaml files are touched: docs and scripts that
# mention a host are prose, not manifests. Any per-file failure fails the tree.
patch_repo_urls_tree() {
    local tree="$1" mode="$2"
    _patch_repo_urls_check_mode "$mode" || return 1
    local changed=0 f n
    while IFS= read -r -d '' f; do
        n="$(patch_repo_urls_file "$f" "$mode" "${f#"$tree"/}")" || return 1
        changed=$((changed + n))
    done < <(find "$tree" -type f -name '*.yaml' -print0)
    echo "$changed"
}
