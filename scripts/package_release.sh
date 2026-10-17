#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:build] release-runtime-closure
# Packaging MUST build and check the selected source release with the locked Nix
# runtime, then export every runtime prerequisite before publishing the final
# .nar and checksum. Local deps and _build MUST NOT supply release inputs.
application=${1:?Usage: package_release.sh marshall|lilly|audi|porsche|ziggy}
case "$application" in marshall|lilly|audi|porsche|ziggy) ;; *) exit 2 ;; esac
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"
mkdir -p -- "$repo_root/artifacts"
nix build --no-link --no-update-lock-file ".#checks.x86_64-linux.$application-release"
nix build --no-update-lock-file ".#$application" --out-link "$repo_root/artifacts/$application"
bundle=$(readlink -f -- "$repo_root/artifacts/$application")
closure_paths=$(nix-store --query --requisites "$bundle")
mapfile -t closure <<< "$closure_paths"
[[ ${#closure[@]} -gt 0 && -n ${closure[0]} ]]
nix-store --export "${closure[@]}" > "$repo_root/artifacts/$application.nar.tmp"
mv -- "$repo_root/artifacts/$application.nar.tmp" "$repo_root/artifacts/$application.nar"
(cd -- "$repo_root/artifacts" && sha256sum "$application.nar" > "$application.nar.sha256")
printf '%s\n' "$bundle" > "$repo_root/artifacts/$application.store-path"
printf 'Release and complete Nix closure: %s/artifacts/%s\n' "$repo_root" "$application"
