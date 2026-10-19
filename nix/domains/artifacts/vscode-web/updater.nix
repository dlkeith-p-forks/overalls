{ pkgs, vscodeWeb }:
let
  python = pkgs.python313;
  node = import ./node-runtime.nix { inherit pkgs; };
  maintained = pkgs.runCommand "overalls-extension-maintenance-source" { } ''
    mkdir -p "$out"
    cp ${./extensions.py} "$out/extensions.py"
    cp ${./update-extensions.py} "$out/update-extensions.py"
  '';
in
# @cc [owner:ghuntley,label:security] extension-updater-packaged-trust
# The maintenance command MUST use the current package's validator/key ring and
# editor version. User options MUST NOT replace those reviewed trust inputs.
pkgs.writeShellApplication {
  name = "update-vscode-extensions";
  runtimeInputs = [ python ];
  text = ''
    for argument in "$@"; do
      case "$argument" in
        --node|--node=*|--validator|--validator=*|--key|--key=*|--editor-version|--editor-version=*)
          printf '%s\n' 'extension_updater_trust_override_refused' >&2
          exit 2
          ;;
      esac
    done
    exec ${python}/bin/python3 ${maintained}/update-extensions.py \
      --node ${node}/bin/node \
      --validator ${vscodeWeb}/lib/overalls-maintenance/check-extension.mts \
      ${pkgs.lib.concatMapStringsSep " " (key: "--key " + pkgs.lib.escapeShellArg (toString key)) vscodeWeb.maintenanceKeyFiles} \
      --editor-version ${pkgs.lib.escapeShellArg vscodeWeb.version} \
      "$@"
  '';
}
