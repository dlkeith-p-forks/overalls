#!/usr/bin/env bash
# Selects flake checks for GitHub Actions from their meta.ci metadata
# (nix/verification/tests/ci.nix).
#
# usage: select-checks.sh machine|build
#   machine  enabled NixOS machine tests
#   build    enabled checks that are not machine tests
#
# Build selection evaluates each check's derivation in isolation with
# nix-eval-jobs, so one check that fails to evaluate does not hide the others
# from the build. Machine selection evaluates only each check's meta.ci:
# forcing a machine test's derivation runs its import-from-derivation guest
# builds, which belong to the matrix job that tests it, not to choosing the
# matrix. All meta.ci values are evaluated together first and, if that fails,
# each check in isolation. Writes `checks` (JSON array of names) and `errors`
# (count) to $GITHUB_OUTPUT and records evaluation errors in the job summary.
# Exits non-zero only when no result can be produced.
set -euo pipefail

# @cc [owner:ghuntley,label:build] ci-check-selection-isolated
# Selection MUST select only checks whose meta.ci enables them for the
# requested kind, MUST NOT force machine-test derivations to choose the matrix,
# and MUST report every evaluation error by attribute instead of letting one
# hide the others or the selection.
kind=${1:?usage: select-checks.sh machine|build}
case "$kind" in
  machine) want=true ;;
  build) want=false ;;
  *) echo "unknown selection: $kind" >&2; exit 2 ;;
esac

work=$(mktemp -d)
results="$work/results"
flake_checks='.#checks.x86_64-linux'

if [ "$kind" = build ]; then
  # Workers share the runner's memory with import-from-derivation builds.
  nix shell --inputs-from . nixpkgs#nix-eval-jobs --command \
    nix-eval-jobs --flake "$flake_checks" --meta \
      --workers 8 --max-memory-size 4096 > "$results"
elif nix eval --json "$flake_checks" --apply 'builtins.mapAttrs (_: check: check.meta.ci)' \
    > "$work/all.json" 2> "$work/all.err"; then
  jq -c 'to_entries[] | {attr: .key, meta: {ci: .value}}' "$work/all.json" > "$results"
else
  echo "Combined meta.ci evaluation failed; evaluating each check in isolation" >&2
  tail -n 5 "$work/all.err" >&2
  nix eval --json "$flake_checks" --apply builtins.attrNames > "$work/names.json"
  jq -r '.[]' "$work/names.json" \
    | xargs -P 8 -I{} bash -c '
        attr=$1 work=$2 flake_checks=$3
        if ci=$(nix eval --json "$flake_checks.\"$attr\".meta.ci" 2> "$work/$attr.err"); then
          jq -c --arg attr "$attr" "{attr: \$attr, meta: {ci: .}}" <<<"$ci"
        else
          jq -cn --arg attr "$attr" --rawfile error "$work/$attr.err" "{attr: \$attr, error: \$error}"
        fi' _ {} "$work" "$flake_checks" > "$results"
fi

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
