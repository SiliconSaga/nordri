# components/nordri/lib/garage.sh
# Find-or-create a named Garage API key without minting a second one.
#
# Garage 2.x does not treat key names as unique: `garage key create <name>`
# succeeds on every run and adds another key with the same name. bootstrap.sh
# used to create first and fall back to `key info` only on failure, so the
# fallback never ran. On homelab a re-run on 2026-09-17 added a second
# velero-service-key and wrote it into Velero's Secret. Its bucket grant by
# name then failed under `|| true`, and Velero's storage location sat
# Unavailable for seven weeks before anyone looked.
#
# So the name is looked up first: no match creates the key, one match reads
# it back with --show-secret (without it Garage 2.x prints "(redacted)", and a
# re-run once wrote that literal into Velero's Secret), and more than one is refused, because which of the
# duplicates a Secret should hold is not something to guess.
#
# The output, secret included, goes straight to a file the caller names
# (created 0600); it never passes through a variable or an argument.
# garage_key_ensure <name> <outfile>

garage_key_ensure() {
    local name="$1" out="$2" list ids matches
    if ! list=$(kubectl exec -n garage garage-0 -- /garage key list 2>/dev/null); then
        echo "⚠️  Could not list Garage keys; not creating $name blind." >&2
        return 1
    fi
    ids=$(printf '%s\n' "$list" | tr -d '\r' | awk -v n="$name" '$3 == n { print $1 }')
    matches=$(printf '%s' "$ids" | awk 'NF { c++ } END { print c + 0 }')
    case "$matches" in
        0)
            ( umask 077; kubectl exec -n garage garage-0 -- /garage key create "$name" > "$out" 2>/dev/null )
            ;;
        1)
            # By the ID from the exact-name match: `key info` takes a search
            # pattern, so passing the name could resolve to some other key.
            ( umask 077; kubectl exec -n garage garage-0 -- /garage key info --show-secret "$ids" > "$out" 2>/dev/null )
            ;;
        *)
            echo "❌ $matches Garage keys are named $name. Keep the one its Secret holds, delete the others with" >&2
            echo "   kubectl exec -n garage garage-0 -- /garage key delete --yes <key-id>, then re-run." >&2
            return 1
            ;;
    esac
}
