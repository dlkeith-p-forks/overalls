# @cc [owner:ghuntley,label:build] compact-source-lock-authority
# Compatibility imports MUST resolve the same immutable GitHub revision recorded
# by the root flake input. They MUST NOT select a branch, ambient checkout or a
# second independently maintained source pin.
let
  lock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  input = lock.nodes.${lock.root}.inputs.nix-compact;
  source = lock.nodes.${input}.locked;
in
assert builtins.isString input;
assert source.type == "github";
assert builtins.isString source.owner && builtins.isString source.repo;
assert builtins.isString source.rev && builtins.match "[0-9a-f]{40}" source.rev != null;
builtins.getFlake "github:${source.owner}/${source.repo}/${source.rev}"
