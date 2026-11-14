# components/nordri/lib/hydrate.sh
# Shared seed-Gitea hydration helpers for bootstrap.sh and update-embedded-git.sh.
# Depends on lib/gitea.sh (gitea_ensure_repo, $GITEA_GIT_BASE, $GITEA_USER) and,
# for the working-tree helper, the caller's TEMP_DIRS array. Trees are pushed as
# they are: no manifest is rewritten on the way in.
#
# Per-script knobs (read here, set by the caller before use):
#   HYDRATE_AUTO_INIT  "true" for fresh-cluster bootstrap (repos need an initial
#                      commit + resolvable HEAD); unset/false for day-2 updates.
#   HYDRATE_COMMITTER  git author name for the ephemeral hydration commit
#                      (default "Nordri Bootstrap").
#
# Every hydration commit records the source checkout's HEAD in a
# `Source-Commit: <sha>` trailer (graduate.sh reads it).

# Copy a source tree into a fresh dir as a clean orphan snapshot (no .git, no
# source history). When the source is a git checkout only tracked and
# untracked-but-not-ignored files are copied, so whatever its .gitignore
# excludes (.env*, kubeconfig, *.key, secrets/ ...) never reaches the seed: no
# credential leaves the operator's machine except inside the pod. A source that
# is not a git checkout is copied whole.
hydrate_prepare_tree() {
    local src="$1" dst="$2" list archive
    if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        list="$(mktemp)" || return 1
        archive="$(mktemp)" || { rm -f "$list"; return 1; }
        if ! git -C "$src" ls-files -co --exclude-standard -z > "$list"; then
            rm -f "$list" "$archive"; return 1
        fi
        # --no-recursion: a nested checkout or submodule shows up as one directory
        # entry; without it tar would carry that repo's .git and ignored files along.
        # Two checked steps, not a pipe: callers run set -e without pipefail, so a
        # failing creator would otherwise hide behind the extractor's status.
        if ! tar --null --no-recursion -C "$src" -cf "$archive" -T "$list"; then
            rm -f "$list" "$archive"; return 1
        fi
        if ! tar -C "$dst" -xf "$archive"; then
            rm -f "$list" "$archive"; return 1
        fi
        rm -f "$list" "$archive"
    else
        cp -r "$src/." "$dst/" || return 1
    fi
    rm -rf "$dst/.git"
    # Belt and braces: no stray .git under a copied directory may reach `git add .`.
    find "$dst" -name .git -prune -exec rm -rf '{}' +
}

# Push a prepared tree to the seed Gitea as a forced fresh main. Runs in a
# subshell so the caller's cwd is untouched even on failure.
hydrate_push_tree() {
    local dir="$1" owner="$2" gitea_repo="$3" commit_msg="$4" src_sha="${5:-unknown}"
    (
        cd "$dir" || exit 1
        git init
        git config user.email "bootstrap@nordri.local"
        git config user.name "${HYDRATE_COMMITTER:-Nordri Bootstrap}"
        git checkout -b main
        git add .
        git commit -q -m "$commit_msg" -m "Source-Commit: $src_sha"
        git remote add origin "$GITEA_GIT_BASE/$owner/$gitea_repo.git"
        git push -u origin main --force
    )
}

# Hydrate one working-tree component into the seed. Warn-and-skip if the source
# dir is absent. The repo is created under <owner>.
hydrate_working_tree_repo() {
    local src_dir="$1" owner="$2" gitea_repo="$3" commit_msg="$4"
    if [[ ! -d "$src_dir" ]]; then
        echo "⚠️  $gitea_repo source not found at: $src_dir — skipping."
        echo "   Set the matching *_DIR env var or clone $gitea_repo as a sibling of nordri."
        return 0
    fi
    echo "💧 Hydrating '$gitea_repo' to Seed Gitea..."
    gitea_ensure_repo "$owner" "$gitea_repo" "${HYDRATE_AUTO_INIT:-false}"
    local tmp src_sha
    src_sha="$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    tmp="$(mktemp -d)"
    TEMP_DIRS+=("$tmp")
    hydrate_prepare_tree "$src_dir" "$tmp"
    hydrate_push_tree "$tmp" "$owner" "$gitea_repo" "$commit_msg" "$src_sha"
    rm -rf "$tmp"
    echo "✅ '$gitea_repo' hydrated to Seed Gitea."
}

# Vendor mirrors: mirror each local clone's REAL history + tags into the seed so
# in-cluster apps can pin an exact upstream ref (a tag, as keycloak-operator
# pins 26.6.3, or a branch). Space-separated list of component dir names under
# the workspace components/.
#
# Heads are pushed WITHOUT --prune (pruning would try to delete the seed's
# default branch and Gitea rejects that, failing the hydration). Tags DO get
# --prune — a retracted tag should disappear and tag pruning can't hit that
# trap. Reads as-fetched remote-tracking refs (no network) — refresh a mirror
# with `ws pull <vendor>`.
hydrate_vendor_mirrors() {
    local owner="$1" mirrors="$2"
    local vendor vendor_dir vendor_branch vendor_remote vendor_seed vref vbranch vr_count
    for vendor in $mirrors; do
        vendor_dir="$(dirname "$SCRIPT_DIR")/$vendor"
        # Plumbing check, not `-d .git`: a worktree/submodule has `.git` as a FILE.
        if git -C "$vendor_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "💧 Updating vendor mirror '$vendor' in Seed Gitea..."
            gitea_ensure_repo "$owner" "$vendor"
            # Resolve the source remote robustly (ws clone names it after the org,
            # not "origin"): prefer the tracking remote, fall back to a sole remote,
            # warn-and-skip if ambiguous rather than guess.
            vendor_branch="$(git -C "$vendor_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
            vendor_remote=""
            [[ -n "$vendor_branch" ]] && vendor_remote="$(git -C "$vendor_dir" config "branch.$vendor_branch.remote" 2>/dev/null || true)"
            if [[ -z "$vendor_remote" ]]; then
                vr_count="$(git -C "$vendor_dir" remote | grep -c . || true)"
                if [[ "$vr_count" != "1" ]]; then
                    echo "⚠️  Vendor mirror '$vendor' has $vr_count remotes and no tracked upstream — skipping (set a single remote or a tracking branch)." >&2
                    continue
                fi
                vendor_remote="$(git -C "$vendor_dir" remote)"
            fi
            vendor_seed="$GITEA_GIT_BASE/$owner/$vendor.git"
            # Default branch (reliably a local head) + every non-default upstream
            # branch (remote-tracking, minus the HEAD symref), each mapped to a seed head.
            local -a refspecs=("+refs/heads/*:refs/heads/*")
            while IFS= read -r vref; do
                vbranch="${vref#refs/remotes/$vendor_remote/}"
                [[ "$vbranch" == "HEAD" ]] && continue
                refspecs+=("+$vref:refs/heads/$vbranch")
            done < <(git -C "$vendor_dir" for-each-ref --format='%(refname)' "refs/remotes/$vendor_remote")
            git -C "$vendor_dir" push --force "$vendor_seed" "${refspecs[@]}"
            git -C "$vendor_dir" push --force --prune "$vendor_seed" 'refs/tags/*:refs/tags/*'
            echo "✅ Vendor mirror '$vendor' updated."
        else
            echo "⚠️  Vendor mirror '$vendor' not cloned at: $vendor_dir"
            echo "   Run 'ws clone $vendor' if apps on this cluster pin it."
        fi
    done
}
