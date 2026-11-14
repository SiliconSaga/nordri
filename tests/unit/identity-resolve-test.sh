#!/usr/bin/env bash
# Unit test for lib/identity.sh: flat-file parsing, the three layers, the lab
# default for an undeclared cluster, the gke gcpProject requirement, and the
# tailnet default (realm Phase 3 design, Decision 3 and the 2026-11-13 review).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/lib/identity.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/realm/clusters"
cat > "$work/realm/clusters/homelab-prod.yaml" <<'EOF'
# a declared prod cluster
role: prod
maturity: durable
sourceRef: main
environment: homelab
EOF
cat > "$work/realm/clusters/gke-prod.yaml" <<'EOF'
environment: gke
role: prod
maturity: bootstrap
sourceRef: live
tailnetNode: gke
gcpProject: example-project
EOF
cat > "$work/realm/clusters/gke-bad.yaml" <<'EOF'
environment: gke
role: test
maturity: bootstrap
EOF
cat > "$work/realm/clusters/homelab-test.yaml" <<'EOF'
environment: homelab
role: test
maturity: bootstrap
tailnetNode: stamped
EOF
cat > "$work/nested.yaml" <<'EOF'
role: prod
backups:
  enabled: true
EOF

# Parsing
out=$(identity_read_flat "$work/realm/clusters/homelab-prod.yaml")
check "comments and blanks skipped, four keys" "[[ \$(printf '%s\n' \"\$out\" | wc -l) -eq 4 ]]"
check "key=value form" "[[ \"\$out\" == *'maturity=durable'* ]]"
identity_read_flat "$work/nested.yaml" >/dev/null 2>&1; rc=$?
check "a nested file is refused" "[[ $rc -eq 1 ]]"
printf 'environment: homelab\nrole: prod\nmaturity: durable\nbackups:\n  enabled: true\n' > "$work/realm/clusters/homelab-nested.yaml"
identity_resolve "$work/realm" homelab-nested >/dev/null 2>&1; rc=$?
check "a nested realm file fails identity_resolve" "[[ $rc -eq 1 ]]"

# A typo'd key is refused, not silently ignored
printf 'environment: homelab\nrole: prod\nmaturity: durable\nstorageclass: fast\n' > "$work/realm/clusters/homelab-typo.yaml"
err=$(identity_resolve "$work/realm" homelab-typo 2>&1 >/dev/null); rc=$?
check "an unknown realm-file key is refused" "[[ $rc -eq 1 && \"\$err\" == *storageclass* ]]"
# The environment names a defaults file, so it is validated before it is used as a path
printf 'environment: ../identity/defaults-gke\nrole: prod\nmaturity: durable\n' > "$work/realm/clusters/homelab-path.yaml"
err=$(identity_resolve "$work/realm" homelab-path 2>&1 >/dev/null); rc=$?
check "an environment that is not [a-z0-9-]+ is refused" "[[ $rc -eq 1 && \"\$err\" == *\"environment '../identity/defaults-gke'\"* ]]"
check "the refusal is the validation, not the missing-file message" "[[ \"\$err\" != *'no '*defaults-* ]]"
printf 'environment: Homelab\nrole: prod\nmaturity: durable\n' > "$work/realm/clusters/homelab-upper.yaml"
identity_resolve "$work/realm" homelab-upper >/dev/null 2>&1; rc=$?
check "an upper-case environment is refused" "[[ $rc -eq 1 ]]"

# Layer 1 + 2: realm file over environment defaults
out=$(identity_resolve "$work/realm" homelab-prod)
check "cluster name recorded" "[[ \"\$out\" == *'cluster=homelab-prod'* ]]"
check "defaults supply storageClass" "[[ \"\$out\" == *'storageClass=local-path'* ]]"
check "realm file supplies maturity" "[[ \"\$out\" == *'maturity=durable'* ]]"
check "prod tailnet defaults to the cluster name" "[[ \"\$out\" == *'tailnetNode=homelab-prod'* ]]"

# Layer 3: env override wins
out=$(NORDRI_IDENTITY_DOMAIN=lab.example identity_resolve "$work/realm" homelab-prod)
check "env var overrides the merged value" "[[ \"\$out\" == *'domain=lab.example'* ]]"

# An undeclared cluster is a lab at bootstrap on homelab, with no tailnet node
out=$(identity_resolve "$work/realm" homelab-spare)
check "lab default role" "[[ \"\$out\" == *'role=lab'* ]]"
check "lab default maturity" "[[ \"\$out\" == *'maturity=bootstrap'* ]]"
check "lab default environment" "[[ \"\$out\" == *'environment=homelab'* ]]"
check "lab has no tailnet node" "[[ \"\$out\" == *'tailnetNode='$'\n'* || \"\$out\" == *'tailnetNode=' ]]"

# gke needs a project
out=$(identity_resolve "$work/realm" gke-prod)
check "gke project carried" "[[ \"\$out\" == *'gcpProject=example-project'* ]]"
identity_resolve "$work/realm" gke-bad >/dev/null 2>&1; rc=$?
check "gke without gcpProject is refused" "[[ $rc -eq 1 ]]"

# A stamped test cluster: fresh stamp when none is live, kept when one is
date() { echo "20261113-1430"; }
out=$(identity_resolve "$work/realm" homelab-test)
check "stamped tailnet node" "[[ \"\$out\" == *'tailnetNode=homelab-test-20261113-1430'* ]]"
unset -f date
out=$(IDENTITY_LIVE_TAILNET=homelab-test-20261101-0900 identity_resolve "$work/realm" homelab-test)
check "an existing stamp is kept across re-applies" "[[ \"\$out\" == *'tailnetNode=homelab-test-20261101-0900'* ]]"

# identity_live_value: a failing kubectl is value-or-nothing, exit 0
kubectl() { return 1; }
out=$(identity_live_value cluster); rc=$?
check "identity_live_value is empty and exit 0 when kubectl fails" "[[ $rc -eq 0 && -z \"\$out\" ]]"
unset -f kubectl

# identity_tailnet_default: prod is the cluster, anything else is nothing
check "tailnet default for prod is the cluster" "[[ \$(identity_tailnet_default homelab-prod prod) == homelab-prod ]]"
check "tailnet default for test is empty" "[[ -z \$(identity_tailnet_default homelab-test test) ]]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
