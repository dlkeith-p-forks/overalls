#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:verification] antithesis-python-static-scope
# The repository Python gate MUST check every harness Python tree with the
# pinned Python 3.13 interpreter and runtime wheel closure. Separate project
# roots MUST prevent runnable `schema`, `control` and `origin` imports from
# shadowing repository modules with the same names. New Python source trees
# MUST be assigned to a ty invocation before this check succeeds.

if [[ $# -ne 4 ]]; then
  echo 'usage: static-check.sh TY ROOT_PYTHON313 HARNESS_PYTHON313 ANTITHESIS_WHEELS' >&2
  exit 2
fi

ty_bin=$1
python_bin=$2
harness_python_bin=$3
wheels_dir=$4
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

declare -a workload_files=()
declare -a test_files=()
declare -a fixture_files=()
declare -a guest_files=()
declare -a storage_files=()
declare -a host_files=()
declare -a recorder_files=()
declare -a integration_files=()
declare -a verification_files=()

source_inventory=$(mktemp)
trap 'rm -f "$source_inventory"' EXIT
find antithesis -type d \( -path antithesis/build -o -path antithesis/runtime \
  -o -path antithesis/scratchbook \
  -o -name _build -o -name .venv -o -name __pycache__ \) -prune \
  -o \( -type f -o -type l \) -name '*.py' -print0 | sort -z > "$source_inventory"

while IFS= read -r -d '' source_file; do
  case "$source_file" in
    antithesis/workload/*) workload_files+=("$source_file") ;;
    antithesis/test/*) test_files+=("$source_file") ;;
    antithesis/fixtures/*) fixture_files+=("$source_file") ;;
    antithesis/emulation/guest/*) guest_files+=("$source_file") ;;
    antithesis/emulation/storage/*) storage_files+=("$source_file") ;;
    antithesis/emulation/host/*) host_files+=("$source_file") ;;
    antithesis/emulation/recorder/*) recorder_files+=("$source_file") ;;
    antithesis/integration/*) integration_files+=("$source_file") ;;
    antithesis/verification/*) verification_files+=("$source_file") ;;
    *)
      printf 'Antithesis Python source has no ty scope: %s\n' "$source_file" >&2
      exit 1
      ;;
  esac
done < "$source_inventory"

require_sources() {
  local scope=$1
  shift
  if [[ $# -eq 0 ]]; then
    printf 'Antithesis ty scope is empty: %s\n' "$scope" >&2
    exit 1
  fi
}

require_sources workload "${workload_files[@]}"
require_sources test "${test_files[@]}"
require_sources fixture "${fixture_files[@]}"
require_sources guest "${guest_files[@]}"
require_sources storage "${storage_files[@]}"
require_sources host "${host_files[@]}"
require_sources integration "${integration_files[@]}"
require_sources verification "${verification_files[@]}"

"$ty_bin" check --python "$python_bin"
"$ty_bin" check --project antithesis/workload --python "$harness_python_bin" \
  --extra-search-path "$wheels_dir/lib/python3.13/site-packages" \
  --extra-search-path antithesis/workload \
  "${workload_files[@]}"
"$ty_bin" check --python "$harness_python_bin" \
  --extra-search-path "$wheels_dir/lib/python3.13/site-packages" \
  --extra-search-path antithesis/workload "${test_files[@]}"
"$ty_bin" check --project antithesis/fixtures --python "$harness_python_bin" \
  --extra-search-path antithesis/fixtures "${fixture_files[@]}"
"$ty_bin" check --python "$harness_python_bin" \
  --extra-search-path antithesis/emulation/guest "${guest_files[@]}"
"$ty_bin" check --python "$harness_python_bin" \
  --extra-search-path antithesis/emulation/storage "${storage_files[@]}"
"$ty_bin" check --python "$harness_python_bin" "${host_files[@]}"
if [[ ${#recorder_files[@]} -gt 0 ]]; then
  "$ty_bin" check --python "$harness_python_bin" \
    --extra-search-path antithesis/emulation/recorder "${recorder_files[@]}"
fi
"$ty_bin" check --project antithesis/integration --python "$harness_python_bin" \
  --extra-search-path antithesis/integration "${integration_files[@]}"
"$ty_bin" check --python "$harness_python_bin" \
  --extra-search-path antithesis/verification "${verification_files[@]}"
