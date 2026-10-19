{ pkgs, module, packages }:
let
  relay = import ../susan-service/relay.nix { inherit pkgs packages; };
in pkgs.testers.runNixOSTest {
  name = "overalls-susan-secrets";
  nodes = {
    relay = { ... }: { imports = [ module relay.node ]; };
    wrong = { lib, ... }: {
      imports = [ module ];
      system.stateVersion = "26.05";
      services.openssh.enable = true;
      services.susan = {
        enable = true;
        secretsFile = "/run/susan-sealed/susan.enc.json";
        apnsTopics = [ "dev.overalls.mila" ];
      };
      systemd.services.susan.wantedBy = lib.mkForce [ ];
    };
  };
  # @cc [owner:ghuntley,label:verification] susan-secret-delivery
  # Susan secrets MUST arrive only through the host-bound SOPS bundle and
  # systemd credentials. Another host MUST NOT decrypt them; a failed
  # publication MUST keep the previous bundle and fence startup; a keyring
  # rotation MUST be audited while older envelopes still open; private values
  # MUST stay outside the journal and the database.
  testScript = builtins.readFile ./driver.py;
}
