{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] mila-desktop-browser-typing
  # The executed browser helper MUST pass its own type check against the same
  # packaged Python and Playwright, independently of the composed driver gate.
  checkedBrowser = pkgs.runCommand "mila-desktop-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # Mila opens approval and documentation links with xdg-open; the test's
  # xdg-open records the link for the browser helper instead of opening one.
  recordingXdgOpen = pkgs.writeShellScriptBin "xdg-open" ''
    umask 077
    printf '%s\n' "$1" > "$HOME/approval-url"
  '';
in (pkgs.testers.runNixOSTest {
  name = "overalls-mila-desktop";
  nodes.control = { config, ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
    virtualisation.memorySize = lib.mkForce 3072;
    services.marshall = {
      enable = true;
      ingress.zone = "apps.example.test";
    };
    # The public origin on 443, as Mila expects: the trust document, approval
    # pages and the browser login all use https://control.example.test.
    services.marshallProxy = {
      enable = true;
      bindAddress = lib.mkForce "0.0.0.0";
      openFirewall = true;
    };
    networking.hosts."127.0.0.1" = [ "control.example.test" ];
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/overalls-test/gateway.token";
      caFile = "/run/overalls-test/ca.crt";
      administrativeAccess = "console";
      openFirewall = true;
    };
    systemd.services.porsche.wantedBy = lib.mkForce [];
    systemd.services.mila-desktop-seed = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=mila-desktop-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  nodes.client = { nodes, ... }: {
    imports = [
      "${pkgs.path}/nixos/tests/common/x11.nix"
      "${pkgs.path}/nixos/tests/common/user-account.nix"
    ];
    test-support.displayManager.auto.user = "alice";
    system.stateVersion = "26.05";
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    networking.hosts.${nodes.control.networking.primaryIPAddress} = [ "control.example.test" ];
    environment.systemPackages = [
      packages.mila.integration
      (lib.hiPrio recordingXdgOpen)
      pkgs.xdotool
      pkgs.curl
      pkgs.chromium
      pkgs.nssTools
      python
      (pkgs.writeShellScriptBin "mila-desktop-browser" ''
        exec ${python}/bin/python ${checkedBrowser}/browser.py "$@"
      '')
    ];
  };
  # The driver is formatted, linted and annotation-checked standalone; its
  # type check runs on the composed driver.
  testScript = builtins.readFile ./driver.py;
}) // { inherit checkedBrowser; }
