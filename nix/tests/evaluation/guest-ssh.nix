{ pkgs }:
let
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [ ../../packages/guest/configuration.nix ];
  };
  sshd = guest.config.systemd.services.sshd;
in
assert guest.config.services.openssh.settings.PermitRootLogin == "no";
assert guest.config.services.openssh.settings.AuthorizedKeysFile == "none";
assert guest.config.services.openssh.settings.PasswordAuthentication == false;
assert guest.config.services.openssh.settings.AllowTcpForwarding == false;
# no-serial-login-shell: no generated or packaged getty on the serial console.
assert builtins.elem "systemd.getty_auto=0" guest.config.boot.kernelParams;
assert !guest.config.systemd.services."serial-getty@".enable;
assert !guest.config.systemd.services."console-getty".enable;
assert guest.config.systemd.services.lilly-console-ready.serviceConfig.TTYPath == "/dev/ttyS0";
pkgs.runCommand "lilly-guest-ssh-check" {} ''
  touch $out
''
