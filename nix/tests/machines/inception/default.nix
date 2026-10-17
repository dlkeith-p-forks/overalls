{ pkgs, packages }:
let
  # @cc [owner:ghuntley,label:verification] inception-browser-subprocess-typing
  # The executed browser helper MUST pass its own type check against the same
  # packaged Python and Playwright; the guest-side copy MUST use the checked bytes.
  checkedBrowser = pkgs.runCommand "inception-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${pkgs.python3.withPackages (p: [ p.playwright ])}/bin/python3 "$out/browser.py"
  '';
  # Public trust is filled from the running isolated issuer before Marshall
  # starts. No private issuer key or parent credential enters this envelope.
  publicSettings = pkgs.writeText "inception-fixture-public-settings.json" (builtins.toJSON {
    issuer = "https://11.0.0.2:9443/dir";
    accept_terms = true;
    nameservers = [
      { name = "ns1.inception.test"; address = "11.0.0.3"; port = 53; }
      { name = "ns2.inception.test"; address = "11.0.0.4"; port = 53; }
    ];
    mailbox = "hostmaster.inception.test"; issuer_ca_pem = null; trust_pem = null;
  });
  # @cc [owner:ghuntley,label:verification;protocol] inception-fixture-complete-image-validator
  # Standalone image identity validation MUST load EditorRelease before
  # ImageManifest and derive the ID from the packaged manifest without a second
  # identity algorithm, even when this fixture consumes a legacy image.
  imageId = pkgs.runCommand "native-inception-image-id" { nativeBuildInputs = [ packages.toolchain.elixir ]; } ''
    export ERL_FLAGS="+S 2:2"
    elixir -r ${../../../../protocol/lib/overalls_protocol/editor_release.ex} -r ${../../../../protocol/lib/overalls_protocol/image_manifest.ex} -e '
      [source, output] = System.argv()
      {:ok, image} = source |> File.read!() |> JSON.decode!() |> OverallsProtocol.ImageManifest.validate()
      File.write!(output, image.id)
    ' ${packages.inceptionGuest}/manifest.json "$out"
  '';
in
(pkgs.testers.runNixOSTest {
  name = "overalls-inception";
  globalTimeout = 14400;
  requiredFeatures.nested-kvm = true;
  nodes.ns1 = import ./public-dns.nix { inherit packages; address = "11.0.0.3"; };
  nodes.ns2 = import ./public-dns.nix { inherit packages; address = "11.0.0.4"; };
  nodes.outer = { config, lib, ... }: {
    imports = [ (import ../../support/role-node.nix {
      inherit packages;
      module = import ../../../modules/default.nix { inherit packages; };
    }) ];
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    networking.enableIPv6 = false;
    networking.hosts."11.0.0.1" = [ "control.example.test" ];
    networking.firewall.interfaces.eth1.allowedTCPPorts = [ 5443 ];
    networking.dhcpcd.denyInterfaces = [ "lu*" ];
    networking.interfaces.eth1.ipv4.addresses = [
      { address = "11.0.0.1"; prefixLength = 24; }
      { address = "11.0.0.5"; prefixLength = 24; }
    ];
    boot.supportedFilesystems = [ "zfs" ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = lib.mkForce 90112;
    virtualisation.cores = lib.mkForce 36;
    virtualisation.diskSize = 32768;
    virtualisation.emptyDiskImages = [ {
      size = 1048576;
      driveConfig.driveExtraOpts.cache = "writeback";
    } ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    services.lilly = {
      enable = true;
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = lib.mkForce "https://control.example.test:5443";
      egressInterface = "eth1";
      guestCpuCores = lib.mkForce 32;
      guestMemoryMiB = lib.mkForce 69632;
      images = [ { path = "${packages.inceptionGuest}"; } ];
      inceptionImageId = builtins.readFile imageId;
      inceptionSMTPFile = "/run/inception-test/smtp.json";
      ingress.enable = true;
    };
    # The nested probe may exhaust the ordinary service deadline while this
    # QEMU fixture copies its large probe disk. Preserve the probe's own bound
    # and require its boot receipt before the test proceeds.
    systemd.services.lilly-inception-preflight.serviceConfig.TimeoutStartSec = lib.mkForce 900;
    # The enrolled Lilly release below consumes production outer dispatch.
    systemd.services.lilly.enable = false;
    # Like the fixture's manually enrolled Lilly, private service enrollment is
    # a separate phase. Keep the required Ziggy module enabled, but do not start
    # it with an invented host credential or provider key in this lifecycle test.
    # This fixture makes no private inference acceptance claim.
    services.ziggy.secretsFile = "/run/inception-outer/ziggy.enc.json";
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    # The fixture enrolls its test Lilly explicitly and does not exercise named
    # edge integrations; keep Galileo configured but out of the boot target.
    services.galileo.secretsFile = "/run/inception-outer/galileo.enc.json";
    systemd.services.galileo.wantedBy = lib.mkForce [];
    services.marshall = {
      enable = true;
      instances.outer.fleetBindAddress = "11.0.0.1";
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      inceptionImageId = builtins.readFile imageId;
      ingress.zone = "apps.inception.test";
      ingress.wildcardAcme = {
        issuerInstance = "outer";
        directory = "https://11.0.0.2:9443/dir";
        issuerCaFile = "/run/inception-public-issuer-ca.pem";
        certificateRootsFile = "/run/inception-public-roots.pem";
        acceptTerms = true;
        nameservers = [
          { address = "11.0.0.3"; port = 53; }
          { address = "11.0.0.4"; port = 53; }
        ];
      };
      ingress.inceptionPublicFile = "/run/inception-public-settings.json";
      secretUnits = [ "inception-public-settings.service" ];
    };
    services.marshallProxy = { enable = true; bindAddress = lib.mkForce "11.0.0.1"; openFirewall = true; };
    services.audi = {
      enable = true;
      administrativeAccess = "console";
      bindAddress = "11.0.0.5";
      openFirewall = true;
      # The template identity is replaced by the dynamically enrolled host in
      # the private runtime credential below; it never authorizes this fixture.
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://control.example.test:5443";
      credentialFile = "/run/inception-outer/audi.token";
      caFile = "/run/overalls-test/ca.crt";
      tls = {
        enable = true;
        zone = "apps.inception.test";
        browserOrigin = "https://control.example.test";
        certificateRootsFile = "/run/inception-public-roots.pem";
      };
    };
    services.postgresql.package = pkgs.postgresql_18;
    systemd.services.audi = {
      wantedBy = lib.mkForce [];
      environment.AUDI_CONFIG_FILE = lib.mkForce "/run/credentials/audi.service/runtime.json";
      serviceConfig.LoadCredential = [ "runtime.json:/run/inception-outer/audi.json" ];
    };
    systemd.services.inception-public-settings = {
      script = ''
        while ! test -s /run/inception-public-settings.json; do
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 180; };
    };
    systemd.services.marshall-outer = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
    };
    environment.etc."inception-outer.exs".source = ./outer.exs;
    systemd.services."inception-outer@" = {
      environment = {
        PHX_SERVER = "false";
        PHX_HOST = "control.example.test";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-inception-operator";
        MARSHALL_INSTANCE_ID = "inception-operator";
        MARSHALL_DB_TLS = "verify";
        MARSHALL_DB_CA_CERTFILE = "/run/overalls-test/ca.crt";
        MARSHALL_REPLICA_COUNT = "3";
        MARSHALL_DB_CONNECTION_BUDGET = "64";
        POOL_SIZE = "2";
        ERL_FLAGS = "+S 2:2";
        ERL_CRASH_DUMP = "/dev/null";
        INCEPTION_IMAGE = "${packages.inceptionGuest}";
        INCEPTION_PROBE_IMAGE = "${packages.inceptionProbeGuest}";
        INCEPTION_TOOLS = "${packages.lilly}/overalls-release.json";
        INCEPTION_ID_BINARY = "${pkgs.coreutils}/bin/id";
      };
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        TimeoutStartSec = 2700;
        EnvironmentFile = "/run/overalls-test/marshall.env";
        ExecStart = pkgs.writeShellScript "inception-outer-operator" ''
          export INCEPTION_OUTER_ACTION="$1"
          export MARSHALL_INCEPTION_IMAGE_ID=${builtins.readFile imageId}
          export MARSHALL_INSTANCE_ID=inception-operator MARSHALL_DB_TLS=verify
          unset PORT
          exec ${packages.marshall}/bin/marshall eval 'Code.eval_file("/etc/inception-outer.exs")'
        '' + " %i";
      };
    };
    systemd.services.inception-outer-lilly = {
      path = [ config.boot.zfs.package "${packages.lilly}/host-tools" pkgs.systemd ];
      environment = {
        LILLY_CONFIG_FILE = "/run/inception-outer/lilly.json";
        LILLY_STATUS_SOCKET = "/run/inception-outer/status.sock";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-inception-lilly";
        RELEASE_TMP = "/run/inception-outer/release";
        ERL_FLAGS = "+S 2:2";
        ERL_CRASH_DUMP = "/dev/null";
      };
      serviceConfig = { Type = "exec"; UMask = "0077"; };
      script = ''
        mkdir -p "$RELEASE_TMP"
        exec ${packages.lilly}/bin/lilly start
      '';
    };
    environment.etc."inception-probe.exs".source = ./probe.exs;
    environment.etc."inception-public-settings.json".source = publicSettings;
    environment.etc."inception-dns-probe.py".source = ./dns_probe.py;
    environment.etc."inception-wildcard-probe.py".source = ./wildcard_probe.py;
    environment.etc."inception-inner.exs".source = ./inner.exs;
    environment.etc."inception-inner-physical.exs".source = ./inner_physical.exs;
    environment.etc."inception-inner-ziggy.exs".source = ./inner_ziggy.exs;
    environment.etc."inception-inner-browser.exs".source = ./inner_browser.exs;
    environment.etc."inception-provider-configure.py".source = ./provider_configure.py;
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq pkgs.python3
    (pkgs.writeShellScriptBin "inception-probe" ''
      export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
      export ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
      export RELEASE_COOKIE=isolated-inception-fixture RELEASE_TMP=/run/inception-probe-release
      umask 077
      mkdir -p "$RELEASE_TMP" /run/inception-test
      {
        date -u +"wrapper start %s"
        id -u
        stat -c 'image %n' ${packages.inceptionGuest}/manifest.json
      } > /run/inception-test/probe-steps.log 2>&1
      export INCEPTION_ACTION="$1" INCEPTION_GENERATION="''${2:-1}"
      export INCEPTION_MANAGED="''${3:-0}" INCEPTION_INSTANCE="''${4:-1}"
      export INCEPTION_IMAGE=${packages.inceptionGuest}
      export INCEPTION_PROBE_IMAGE=${packages.inceptionProbeGuest}
      export INCEPTION_TOOLS=${packages.lilly}/overalls-release.json
      exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/inception-probe.exs")'
    '')
    ];
  };
  nodes.internet = { ... }: {
    imports = [ ./public-issuer.nix ];
    environment.systemPackages = [
      pkgs.bind.dnsutils
      pkgs.chromium
      (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.playwright ]))
    ];
    environment.etc."inception-browser.py".source = checkedBrowser + "/browser.py";
    system.stateVersion = "26.05";
    virtualisation.memorySize = 3072;
    networking.enableIPv6 = false;
    networking.interfaces.eth1.ipv4.addresses = [ { address = "11.0.0.2"; prefixLength = 24; } ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.public-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /etc";
    };
  };
  testScript = builtins.readFile ../../support/transfer.py + "\n" + builtins.readFile ./driver.py;
}) // { inherit checkedBrowser; }
