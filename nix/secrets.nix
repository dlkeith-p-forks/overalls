# @cc [owner:ghuntley,label:security] authenticated-secret-host-inputs
# Host recipients and host documents MUST derive from the authoritative host inventory.
# Declarations MUST contain authenticated public keys and ciphertext references only.
{ lib }:
let
  inventory = (import ./hosts/inventory.nix { inherit lib; }).secrets;
in
assert lib.assertMsg (lib.all (name: !(builtins.hasAttr name inventory.documents)) [ "git-bootstrap" "marshall-bootstrap" "crash-dump-bootstrap" "private-ca-recovery" "brady-ca-recovery" "ssh-host-ca-recovery" "logstore-ca-recovery" "service-ca-recovery" ]) "Bootstrap documents are reserved for recovery-only custody";
inventory // {
  documents = inventory.documents // {
    ssh-host-ca-recovery = {
      path = "secrets/ssh-host-ca-recovery.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    brady-ca-recovery = {
      path = "secrets/brady-ca-recovery.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    private-ca-recovery = {
      path = "secrets/private-ca-recovery.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    logstore-ca-recovery = {
      path = "secrets/logstore-ca-recovery.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    service-ca-recovery = {
      path = "secrets/service-ca-recovery.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    git-bootstrap = {
      path = "secrets/git-bootstrap.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    marshall-bootstrap = {
      path = "secrets/marshall-bootstrap.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
    crash-dump-bootstrap = {
      path = "secrets/crash-dump-bootstrap.enc.json";
      hosts = [];
      recoveryOnly = true;
    };
  };
}
