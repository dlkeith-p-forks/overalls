{ pkgs, packages }:
let
  image = packages.mkArchGuest { imageName = "pam-helper-runtime-input"; };
  probe = pkgs.replaceVars ./foreign_linux_pam_account_probe.py { pam = pkgs.pam; };
  runtimeCheck = pkgs.replaceVars ./foreign_linux_pam_helpers.py {
    installer = image.pamHelperInstaller;
    pam = pkgs.pam;
    chroot = "${pkgs.coreutils}/bin/chroot";
    mount = "${pkgs.util-linux}/bin/mount";
    unshare = "${pkgs.util-linux}/bin/unshare";
    python = "${pkgs.python3}/bin/python3";
    inherit probe;
  };
in
# @cc [owner:ghuntley,label:verification;security] foreign-linux-pam-helper-vm-gate
# The bounded gate MUST execute the actual pinned installer and PAM library in
# an isolated VM/chroot without production accounts or credentials. It MUST
# check unsafe-node refusals and root account checks on nosuid runtime storage;
# it MUST NOT claim foreign guest boot, SSH or nonroot privilege acceptance.
pkgs.vmTools.runInLinuxVM (pkgs.runCommand "foreign-linux-pam-helper-runtime" {
  memSize = 512;
  passthru = { inherit runtimeCheck probe; };
} ''
  mkdir -p /tmp "$out"
  chmod 1777 /tmp
  ${pkgs.python3}/bin/python3 ${runtimeCheck} > "$out/receipt.json"
'')
