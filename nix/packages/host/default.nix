{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  source = pkgs.runCommand "overalls-host-source" {} ''
    mkdir -p $out
    cp ${./.}/*.py $out/
    cp ${../secrets/cli.py} $out/secrets_cli.py
  '';
  anywhere = import ./installer.nix { inherit pkgs; };
in pkgs.writeShellApplication {
  name = "host";
  runtimeInputs = [ python pkgs.sops pkgs.age pkgs.ssh-to-age pkgs.nix pkgs.git pkgs.openssh anywhere ];
  text = ''
    exec ${python}/bin/python ${source}/cli.py "$@"
  '';
}
