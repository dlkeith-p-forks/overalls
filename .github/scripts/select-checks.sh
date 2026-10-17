#!/usr/bin/env bash
# Selects flake checks for GitHub Actions from their meta.ci metadata
# (nix/verification/tests/ci.nix).
#
# usage: select-checks.sh machine|build
#   machine  enabled NixOS machine tests
#   build    enabled checks that are not machine tests
#
# Each check is evaluated in isolation with nix-eval-jobs, so one check that
# fails to evaluate does not hide the others. Writes `checks` (JSON array of
# names) and `errors` (count) to $GITHUB_OUTPUT and records evaluation errors
# in the job summary. Exits non-zero only when no result can be produced.
set -euo pipefail

kind=${1:?usage: select-checks.sh machine|build}
case "$kind" in
  machine) want=true ;;
  build) want=false ;;
  *) echo "unknown selection: $kind" >&2; exit 2 ;;
esac

results=$(mktemp)
nix shell --inputs-from . nixpkgs#nix-eval-jobs --command \
  nix-eval-jobs --flake '.#checks.x86_64-linux' --meta \
    --workers "$(nproc)" --max-memory-size 4096 > "$results"

# Every line must be a JSON object naming its attribute.
jq -e -s 'all(type == "object" and (.attr | type == "string"))' "$results" > /dev/null

checks=$(jq -c -s --argjson want "$want" '
  map(select(has("error") | not)
      | select(.meta.ci.enable == true and .meta.ci.machine == $want)
      | .attr) | sort' "$results")
errors=$(jq -c -s 'map(select(has("error")) | {attr, error}) | sort_by(.attr)' "$results")
error_count=$(jq length <<<"$errors")

echo "Selected $(jq length <<<"$checks") $kind checks: $checks"
{
  echo "checks=$checks"
  echo "errors=$error_count"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$error_count" -gt 0 ]; then
  {
    echo "### Checks that failed to evaluate ($error_count)"
    jq -r '.[] | "- `\(.attr)`: \(.error | split("\n") | map(select(test("error:"))) | last // "evaluation error" | ltrimstr(" ") )"' <<<"$errors"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  jq -r '.[] | "::error title=\(.attr) does not evaluate::\(.error | split("\n") | map(select(test("error:"))) | last // "evaluation error")"' <<<"$errors"
fi
