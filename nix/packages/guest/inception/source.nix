{ lib }:
let
  root = ../../../..;
  roots = [ "AGENTS.md" "CONTRACTS" "README.md" ".gitignore" ".tool-versions" ".agents"
    "flake.nix" "flake.lock" "devenv.nix" "devenv.yaml" "devenv.lock"
    "marshall" "lilly" "protocol" "audi" "porsche" "ziggy" "docs" "scripts" "nix" "tools" "fleet" ];
in
# @cc [owner:ghuntley,label:security;build] inception-development-source-boundary
# The development source MUST exclude production secret documents, repository
# credentials, local dependencies/builds and generated assets. It MUST preserve
# maintained application, protocol, Nix, test and contract sources.
lib.cleanSourceWith {
  name = "inception-development-source";
  src = root;
  filter = path: type:
    let
      relative = lib.removePrefix (toString root + "/") (toString path);
      parts = lib.splitString "/" relative;
      blocked = [ ".git" "deps" "_build" "node_modules" "__pycache__" "target" ".direnv" ];
    in path == toString root || (
      builtins.elem (builtins.head parts) roots
      && !lib.any (part: builtins.elem part blocked || lib.hasPrefix ".devenv" part) parts
      && !lib.hasSuffix ".env" relative
      && !lib.hasPrefix "marshall/priv/static/assets/" relative
      && relative != "marshall/priv/static/cache_manifest.json"
    );
}
