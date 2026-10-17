{ pkgs, users ? import ../../../policy/identity/users.nix, inventory ? import ../../../policy/secrets/secret-documents.nix { inherit (pkgs) lib; } }:
let
  registry = (import ../../../platform/lib/registry.nix { inherit (pkgs) lib; }).normalize users inventory;
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  toolPath = pkgs.lib.makeBinPath [ pkgs.sops pkgs.ssh-to-age pkgs.age pkgs.openssh ];
  manifest = pkgs.writeText "overalls-public-registry.json" (builtins.toJSON registry);
  recipients = pkgs.runCommand "overalls-user-recipients" {} ''
    export PATH=${toolPath}:$PATH
    ${python}/bin/python ${./cli.py} --manifest ${manifest} export --output "$out"
  '';
  command = pkgs.writeShellApplication {
    name = "overalls-secrets";
    runtimeInputs = [ pkgs.sops pkgs.ssh-to-age pkgs.age pkgs.openssh ];
    text = ''
      exec ${python}/bin/python ${./cli.py} --manifest ${recipients}/manifest.json "$@"
    '';
  };
in
{ inherit recipients command; }
