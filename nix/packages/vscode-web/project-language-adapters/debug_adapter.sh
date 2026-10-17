#!/bin/sh

# @cc [owner:ghuntley,label:build] project-elixir-debug-adapter
# This adapter MUST execute project PATH elixir-debug-adapter with unchanged
# string arguments. A missing command MUST return 127 with fixed stderr.
if ! command -v elixir-debug-adapter >/dev/null 2>&1; then
  printf '%s\n' 'project_elixir_debug_adapter_unavailable' >&2
  exit 127
fi
exec elixir-debug-adapter "$@"
