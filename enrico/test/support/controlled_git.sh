#!/usr/bin/env bash
set -euo pipefail

# Controlled argument-vector fixture, never a real remote or shell command.
# All accepted commands below have fixed schemas and validated destinations.
while [[ ${1:-} == -c ]]; do
  [[ $# -ge 2 ]] || exit 125
  shift 2
done

declare command=${1:-}
declare root=''
if [[ $command == clone ]]; then
  [[ $# == 5 && $2 == --quiet && $3 == --mirror && $4 == https://github.com/NixOS/nixpkgs.git ]] || exit 125
  root=$5
  [[ $root == /*.git.new ]] || exit 125
  mkdir -p -- "$root"
  printf '%s\n' "$$" >> "${root%.new}.pids"
  printf 'clone\n' >> "${root%.new}.calls"
  declare -i waits=0
  while [[ -e ${root%.new}.hold ]]; do
    (( waits += 1 ))
    [[ $waits -le 20000 ]] || exit 125
    sleep 0.01
  done
  [[ ! -e ${root%.new}.fail ]] || exit 42
elif [[ $command == --git-dir=/* ]]; then
  root=${command#--git-dir=}
  [[ -d $root ]] || exit 125
  shift
  case ${1:-} in
    rev-parse)
      [[ $# == 4 && $2 == --verify && $3 == --end-of-options && $4 == 'HEAD^{commit}' ]] || exit 125
      printf '%040d\n' 1
      ;;
    update-ref)
      [[ $# == 3 && $2 == refs/enrico/retained/* && $3 == 0000000000000000000000000000000000000001 ]] || exit 125
      ;;
    *) exit 125 ;;
  esac
else
  exit 125
fi
