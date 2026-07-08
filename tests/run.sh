#!/usr/bin/env bash
# nordri test/lint runner — invoked by the ws adapter (realm adapters/nordri.yaml).
# Cluster-free: syntax-checks the entry-point scripts + libs and runs the lib
# unit tests. The kuttl e2e suites (kuttl-test-*.yaml) need a live cluster and
# are run separately (see docs/kuttl-tests.md), NOT here.
#
# Usage: tests/run.sh [test|lint]   (default: test)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # nordri repo root
shopt -s nullglob   # an empty glob (e.g. lib/*.sh) drops out instead of passing the literal pattern

mode="${1:-test}"
shell_files=(bootstrap.sh update-embedded-git.sh lib/*.sh tests/unit/*.sh tests/run.sh)

syntax_check() {
  local f rc=0
  for f in "${shell_files[@]}"; do
    if ! bash -n "$f"; then echo "  bash -n FAILED: $f" >&2; rc=1; fi
  done
  return $rc
}

case "$mode" in
  lint)
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck "${shell_files[@]}"
    else
      echo "shellcheck not installed — falling back to 'bash -n' syntax lint."
      syntax_check
    fi
    ;;
  test)
    echo "== syntax check =="
    syntax_check || exit 1
    if ! command -v jq >/dev/null 2>&1; then
      echo "❌ jq is required to run the unit tests (lib/gitea.sh uses it). Install jq and re-run." >&2
      exit 1
    fi
    echo "== unit tests =="
    fails=0
    for t in tests/unit/*.sh; do
      echo "RUN $t"
      bash "$t" || fails=$((fails + 1))
    done
    if [ "$fails" -ne 0 ]; then
      echo "❌ $fails unit-test file(s) FAILED" >&2
      exit 1
    fi
    echo "✅ nordri: syntax clean + all unit tests pass"
    ;;
  *)
    echo "Usage: tests/run.sh [test|lint]" >&2
    exit 2
    ;;
esac
