{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-ssh-transfer";
  nodes.endpoint = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 1024;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    users.users.lilly-transfer = {
      isNormalUser = true;
      password = "disposable-fixture-only";
      shell = pkgs.bash;
    };
    services.openssh = {
      enable = true;
      ports = [ 2222 ];
      authorizedKeysFiles = lib.mkForce [ "none" ];
      settings = {
        AuthorizedKeysCommand = "/etc/source-permit-authorize %u %t %k";
        AuthorizedKeysCommandUser = "root";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        AllowUsers = [ "lilly-transfer" ];
        AllowTcpForwarding = false;
        AllowAgentForwarding = false;
        X11Forwarding = false;
        PermitTunnel = false;
        PermitTTY = false;
      };
    };
    environment.systemPackages = [ packages.hostTools packages.lilly
      (pkgs.writeShellScriptBin "ssh-transfer-check" ''
        export PATH="${packages.lilly}/host-tools/bin:/run/current-system/sw/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE=ssh-transfer-fixture
        export RELEASE_TMP=/run/ssh-transfer-release
        mkdir -p "$RELEASE_TMP"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/ssh-transfer-check.exs")'
      '')
    ];
    environment.etc."ssh-transfer-check.exs".source = ./check.exs;
    # Copy to a root-owned regular file: the VM shared store is group-writable
    # and OpenSSH correctly refuses it as an AuthorizedKeysCommand ancestor.
    environment.etc."source-permit-authorize" = {
      mode = "0555";
      source = pkgs.writeShellScript "source-permit-authorize" ''
          export PATH="${packages.lilly}/host-tools/bin:/run/current-system/sw/bin"
          export ERL_FLAGS="+S 2:2"
          export RELEASE_COOKIE=isolated-source-authorize
          export RELEASE_DISTRIBUTION=none
          export RELEASE_TMP=/run/source-authorize-release
          mkdir -p "$RELEASE_TMP"
          export EXPORT_USER="$1" EXPORT_TYPE="$2" EXPORT_KEY="$3"
          exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/source-authorize.exs")'
        '';
    };
    environment.etc."source-authorize.exs".source = ./authorize.exs;
    environment.etc."transfer-export".source = pkgs.writeShellScript "transfer-export" ''
      ${pkgs.coreutils}/bin/touch /tmp/transfer-export-ran
      printf '%s' "$1" > /tmp/authenticated-export-key
      test "$SSH_ORIGINAL_COMMAND" = "lilly-export-v4 aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" || exit 1
      exec ${pkgs.coreutils}/bin/head -c 33554432 /dev/zero
    '';
  };
  testScript = ''
    start_all()
    endpoint.wait_for_unit("sshd.service")
    endpoint.succeed("ssh-transfer-check")
  '';
}
