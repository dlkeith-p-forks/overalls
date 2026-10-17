#!/bin/sh

# @cc [owner:ghuntley,label:build] project-elixir-language-server
# This adapter MUST execute project PATH elixir-ls with unchanged string
# arguments. A missing command MUST return 127 with fixed stderr; no bootstrap.
if ! command -v elixir-ls >/dev/null 2>&1; then
  printf '%s\n' 'project_elixir_ls_unavailable' >&2
  exit 127
fi
exec elixir-ls "$@"
