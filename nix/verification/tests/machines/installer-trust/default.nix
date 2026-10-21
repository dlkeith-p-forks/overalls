{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  # @cc [owner:ghuntley,label:verification] installer-fixture-upgraded-release
  # The upgrade fixture appends one byte to the packaged linux-amd64 artifact and
  # regenerates every manifest digest from the actual bytes, so only the changed
  # artifact's digest may differ from the packaged release.
  upgradedLyra = pkgs.runCommand "overalls-lyra-upgraded" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${packages.lyra} "$out"
    chmod -R u+w "$out"
    printf 'overalls-upgraded-fixture\n' >> "$out/bin/linux-amd64"
    ${pkgs.python3}/bin/python3 - "$out" <<'PYEOF'
    import hashlib
    import json
    import pathlib
    import sys

    root = pathlib.Path(sys.argv[1])
    names = ("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64")
    artifacts = {
        name: {
            "path": "/bin/" + name,
            "sha256": hashlib.sha256((root / "bin" / name).read_bytes()).hexdigest(),
            "bytes": (root / "bin" / name).stat().st_size,
        }
        for name in names
    }
    (root / "manifest.json").write_text(json.dumps({"version": "0.1.0", "artifacts": artifacts}, sort_keys=True))
    PYEOF
  '';
  # @cc [owner:ghuntley,label:verification;security] installer-fixture-mismatched-release
  # The mismatch fixture appends one byte but keeps the packaged manifest, so the
  # served linux-amd64 digest MUST NOT match the served bytes. All other artifacts
  # must stay byte-identical with agreeing digests.
  mismatchedLyra = pkgs.runCommand "overalls-lyra-mismatched" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${packages.lyra} "$out"
    chmod -R u+w "$out"
    printf 'overalls-mismatched-fixture\n' >> "$out/bin/linux-amd64"
    ${pkgs.python3}/bin/python3 - "$out" <<'PYEOF'
    import hashlib
    import json
    import pathlib
    import sys

    root = pathlib.Path(sys.argv[1])
    recorded = json.loads((root / "manifest.json").read_text())["artifacts"]["linux-amd64"]["sha256"]
    actual = hashlib.sha256((root / "bin" / "linux-amd64").read_bytes()).hexdigest()
    assert recorded != actual, "fixture must keep a stale digest"
    PYEOF
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-installer-trust";
  nodes.control = { config, ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
    virtualisation.memorySize = lib.mkForce 3072;
    # Keep both fixture releases in the machine closure; the driver selects the
    # served release through a runtime drop-in.
    system.extraDependencies = [ upgradedLyra mismatchedLyra ];
    services.marshall = {
      enable = true;
      ingress.zone = "apps.example.test";
      instances.control.bindAddress = "0.0.0.0";
    };
    networking.firewall.allowedTCPPorts = [ 4443 ];
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test:4443";
      credentialFile = "/run/overalls-test/gateway.token";
      caFile = "/run/overalls-test/ca.crt";
      administrativeAccess = "console";
      openFirewall = true;
    };
    systemd.services.porsche.wantedBy = lib.mkForce [];
    systemd.services.installer-seed = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=installer-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
    systemd.services.installer-revoke = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=installer-revoke MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./revoke.exs}")'
      '';
    };
    systemd.services.installer-register = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=installer-register MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./register.exs}")'
      '';
    };
  };
  nodes.client = { nodes, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 1024;
    virtualisation.cores = 1;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    networking.extraHosts = ''
      ${nodes.control.networking.primaryIPAddress} control.example.test
    '';
    users.users.tester = { isNormalUser = true; };
    environment.systemPackages = [ pkgs.openssh pkgs.curl pkgs.util-linux ];
  };
  # @cc [owner:ghuntley,label:verification] installer-native-account-proof
  # The journey MUST download the real packaged CLI through Marshall's verified
  # HTTPS endpoint and prove its account through the actual Porsche service.
  # Refused trust MUST preserve prior client state. No guest is provisioned;
  # completion of account setup MUST NOT be reported as guest SSH acceptance.
  testScript = builtins.replaceStrings
    [ "@UPGRADED_RELEASE@" "@MISMATCHED_RELEASE@" ]
    [ "${upgradedLyra}" "${mismatchedLyra}" ]
    (builtins.readFile ./driver.py);
}
