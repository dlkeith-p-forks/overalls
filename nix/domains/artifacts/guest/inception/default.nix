{ packages }:
{ config, lib, pkgs, ... }:
let
  source = import ./source.nix { inherit lib; };
  zfs = config.boot.zfs.package;
  publicConfig = pkgs.writeText "inception-public.json" (builtins.toJSON {
    inherit source;
    guest_image = packages.guest;
    lilly_release = packages.lilly;
    marshall_release = packages.marshall;
    bootstrap = "${./.}/prepare.py";
    openssl = "${pkgs.openssl}/bin/openssl";
    git = "${pkgs.git}/bin/git";
    runuser = "${pkgs.util-linux}/bin/runuser";
    psql = "${pkgs.postgresql_18}/bin/psql";
    sync = "${pkgs.coreutils}/bin/sync";
    id = "${pkgs.coreutils}/bin/id";
    system_ca = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  });
  prepare = action: "${pkgs.python3}/bin/python3 ${./.}/prepare.py ${action} ${publicConfig}";
  operator = file: ''
    export INCEPTION_CONFIG=${publicConfig}
    exec ${prepare "exec"} ${packages.marshall}/bin/marshall eval 'Code.eval_file("${file}")'
  '';
  oneshot = after: script: {
    wantedBy = [ "multi-user.target" ];
    inherit after script;
    requires = after;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; TimeoutStartSec = 300; };
  };
in
{
  # @cc [owner:ghuntley,label:security] inception-excludes-root-guest-ssh
  # Inception exposes its application gateways on port 22 but MUST never enable
  # the parent image's root guest-SSH mechanism from ADR-0093.
  services.openssh.enable = lib.mkForce false;

  imports = [
    (import ../../../system/secrets { inherit packages; })
    (import ../../../system/marshall.nix { inherit packages; })
    (import ./porsche.nix { inherit packages publicConfig; })
    (import ./audi.nix { inherit packages publicConfig; })
    (import ./dns.nix { inherit packages; })
    (import ./private.nix { inherit packages; })
    (import ./ziggy.nix { inherit packages; })
    ./ssh-host-ca.nix
    ./control.nix
  ];
  networking.hostName = lib.mkForce "inception";
  boot.kernelModules = [ "kvm" ];
  boot.extraModulePackages = [ config.boot.zfs.modulePackage ];
  boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.dhcpcd.denyInterfaces = [ "lu*" ];
  networking.firewall.extraForwardRules = ''
    iifname "lu*" oifname "eth0" ip saddr 169.254.255.2 ct state { new, established, related } accept
  '';

  environment.systemPackages = [
    pkgs.git pkgs.devenv pkgs.gnumake pkgs.gcc pkgs.pkg-config pkgs.openssl
    pkgs.nodejs pkgs.rustc pkgs.cargo pkgs.python3 pkgs.util-linux pkgs.nftables
    pkgs.jq pkgs.postgresql_18 packages.toolchain.elixir packages.toolchain.erlang
    packages.marshall packages.lilly zfs
  ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.etc."inception-public.json".source = publicConfig;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    enableTCPIP = true;
    ensureDatabases = [ "marshall" ];
    ensureUsers = [ { name = "marshall"; ensureDBOwnership = true; } ];
    authentication = lib.mkForce ''
      local all postgres peer
      local all all peer
      hostssl marshall marshall 127.0.0.1/32 scram-sha-256
    '';
    settings = {
      listen_addresses = lib.mkForce "127.0.0.1";
      password_encryption = "scram-sha-256";
      ssl = true;
      ssl_cert_file = "/run/credentials/postgresql.service/database.crt";
      ssl_key_file = "/run/credentials/postgresql.service/database.key";
      fsync = true;
      full_page_writes = true;
      synchronous_commit = "on";
      max_connections = 100;
    };
  };
  systemd.services.postgresql = {
    after = [ "inception-identity.service" ];
    requires = [ "inception-identity.service" ];
    serviceConfig.LoadCredential = [
      "database.crt:/var/lib/inception/tls/database.crt"
      "database.key:/var/lib/inception/tls/database.key"
    ];
  };

  services.marshall = {
    enable = true;
    replicaCount = 1;
    publicHost = "localhost";
    publicHostFile = "/run/inception/public-host";
    defaultImageIdFile = "/run/inception/default-image-id";
    databaseConnectionBudget = 64;
    environmentFile = "/run/inception/marshall.env";
    databaseCAFile = "/run/inception-public/ca.crt";
    secretUnits = [ "inception-enrollment.service" "inception-namespace.service" ];
    cpuCores = 2;
    memoryMiB = 4096;
    instances.inception = {
      port = 4443;
      certificateFile = "/var/lib/inception/tls/marshall.crt";
      keyFile = "/var/lib/inception/tls/marshall.key";
    };
  };

  # Parent namespace files are private runtime inputs; they must exist before
  # the listener starts. Core migrations still use independent local identity.
  systemd.services.marshall-inception.serviceConfig.EnvironmentFile = lib.mkForce [
    "/run/inception/marshall.env" "/run/inception/namespace.env" "/run/inception/ssh-trust.env"
  ];
  systemd.services.marshall-inception.serviceConfig.LoadCredential = lib.mkAfter [
    "fleet-issuer-ca:/run/inception/audi-issuer-ca.pem"
    "fleet-roots:/run/inception/audi-trust.pem"
  ];

  systemd.services.inception-identity = oneshot [] ''
    ${prepare "identity"}
    if ${pkgs.gnugrep}/bin/grep -qw svm /proc/cpuinfo; then
      ${pkgs.kmod}/bin/modprobe kvm_amd
    elif ${pkgs.gnugrep}/bin/grep -qw vmx /proc/cpuinfo; then
      ${pkgs.kmod}/bin/modprobe kvm_intel
    else
      exit 1
    fi
    test -c /dev/kvm
  '';
  systemd.services.inception-storage = (oneshot [ "inception-identity.service" ] ''
    exec ${pkgs.python3}/bin/python3 ${./.}/storage.py
  '') // { path = [ zfs pkgs.util-linux pkgs.kmod ]; };
  systemd.services.inception-ingress = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-identity.service" ];
    after = [ "inception-identity.service" ];
    serviceConfig = {
      Type = "exec";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 2;
      ExecStart = "${pkgs.python3}/bin/python3 ${./.}/ingress.py ${../.}";
    };
  };
  # @cc [owner:ghuntley,label:recovery] inception-namespace-before-listener
  # Marshall MUST wait for parent namespace files without exhausting startup
  # retries. Namespace reception MUST remain independent of Marshall readiness
  # and certificate issuance, so parent polling can complete initial bootstrap.
  systemd.services.inception-namespace =
    (oneshot [ "inception-ingress.service" ] ''
      while [ ! -s /run/inception/public-host ] || [ ! -s /run/inception/namespace.env ]; do
        ${pkgs.coreutils}/bin/sleep 1
      done
    '') // {
      serviceConfig = {
        Type = "oneshot"; RemainAfterExit = true; UMask = "0077";
        TimeoutStartSec = "infinity";
      };
    };
  systemd.services.inception-dns-identity =
    oneshot [ "inception-enrollment.service" ] (operator ./dns.exs);

  # @cc [owner:ghuntley,label:security;recovery] inception-publication-local-source
  # The publication worker MUST use only inner credentials and verified local
  # IPv4 HTTPS. Its output MUST expire independently of worker health and be
  # fenced by the current parent namespace. Public readiness MUST NOT block
  # namespace reception or core execution readiness.
  systemd.services.inception-publication = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-namespace.service" "inception-dns-identity.service" ];
    after = [ "inception-namespace.service" "inception-dns-identity.service" "marshall-inception.service" ];
    serviceConfig = {
      Type = "exec"; User = "root"; Group = "audi"; UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${./.}/publication.py ${../.}";
      Restart = "on-failure"; RestartSec = 2; TimeoutStopSec = 5;
      CPUQuota = "100%"; MemoryMax = "256M"; TasksMax = 32;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
      ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
      ReadWritePaths = [ "/run/inception" "/run/inception-proofs" ];
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
    };
  };
  systemd.services.inception-credentials = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-identity.service" ];
    after = [ "inception-identity.service" ];
    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      UMask = "0077";
      TimeoutStartSec = "infinity";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStart = "${pkgs.python3}/bin/python3 ${./.}/credentials.py ${../.} ${publicConfig} ${pkgs.systemd}/bin/systemctl";
    };
  };
  systemd.services.inception-environment = oneshot [ "inception-identity.service" "inception-credentials.service" ] ''
    exec ${prepare "environment"}
  '';
  # @cc [owner:ghuntley,label:security;build] inception-nested-image-runtime-trust
  # The nested guest image MUST be rebuilt from the recipe with this
  # instance's public private-service root before enrollment. The rebuild MUST
  # run offline from the prewarmed cache, reject private-key inputs and expose
  # only the resulting content identity to Marshall. Boot MUST NOT proceed with
  # an image that lacks instance trust.
  systemd.services.inception-image = {
    description = "Rebuild nested guest image with instance private trust";
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-private-pki.service" ];
    after = [ "inception-private-pki.service" ];
    serviceConfig = {
      Type = "oneshot"; RemainAfterExit = true; UMask = "0077";
      TimeoutStartSec = 1800;
    };
    script = ''
      set -eu
      # The prewarmed cache retains the whole offline rebuild graph in this
      # system's store; nix below resolves every input from it.
      test -d ${packages.imageBuilder.cache}
      ${pkgs.coreutils}/bin/install -d -m 0700 /run/inception
      log=/run/inception/image-build.log
      status=/run/inception/image-build-status
      ${pkgs.coreutils}/bin/rm -f "$log" "$status"
      trap '${pkgs.coreutils}/bin/rm -f "$log"' EXIT
      if ! ${config.nix.package}/bin/nix build --offline --option substitute false \
        --file ${packages.imageBuilder.recipe} \
        --argstr rootCertificate /run/inception-public/private-root.pem \
        --out-link /var/lib/inception/guest-image >"$log" 2>&1; then
        if ${pkgs.gnugrep}/bin/grep -Eqi 'not allowed to refer to|is not trusted|lacks a signature' "$log"; then
          category=trust-rejected
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'path .*(/nix/store|/run/inception-public).*(is not valid|does not exist)|No such file or directory.*(/nix/store|/run/inception-public)|getting status of .*(/nix/store|/run/inception-public)|cannot (build|realise|copy) missing|no substituter.*path|is required, but there is no substituter' "$log"; then
          category=missing-path
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'No space left on device|disk full|not enough free space' "$log"; then
          category=capacity
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'Permission denied|Operation not permitted|access to .* is forbidden' "$log"; then
          category=permission
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'experimental Nix feature|unknown option.*offline' "$log"; then
          category=feature
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'cannot connect to daemon|error communicating with .*daemon|daemon.*(unavailable|refused)' "$log"; then
          category=daemon
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'assertion.*failed|Nested guest trust requires' "$log"; then
          category=evaluation-assertion
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'access to absolute path|path .* is forbidden|restricted mode|pure evaluation mode' "$log"; then
          category=evaluation-path
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'undefined variable|attribute .* missing' "$log"; then
          category=evaluation-symbol
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'cannot coerce|value is .* while a .* was expected|expected a .* but found' "$log"; then
          category=evaluation-type
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'infinite recursion|stack overflow' "$log"; then
          category=evaluation-recursion
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'evaluation error|while evaluating|syntax error' "$log"; then
          category=evaluation-other
        elif ${pkgs.gnugrep}/bin/grep -Eqi 'builder for .* failed|build of .* failed|failed to produce output path' "$log"; then
          category=builder
        else
          category=other
        fi
        ${pkgs.coreutils}/bin/printf '%s\n' "$category" >"$status"
        ${pkgs.coreutils}/bin/rm -f "$log"
        echo "Inception image rebuild failed: $category" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/rm -f "$log" "$status"
      test -s /var/lib/inception/guest-image/manifest.json
      export ERL_FLAGS="+S 2:2"
      ${packages.toolchain.elixir}/bin/elixir -r ${../../../../../protocol/lib/overalls_protocol/editor_release.ex} -r ${../../../../../protocol/lib/overalls_protocol/image_manifest.ex} -e '
        [source, output] = System.argv()
        {:ok, image} = source |> File.read!() |> JSON.decode!() |> OverallsProtocol.ImageManifest.validate()
        File.write!(output, image.id)
      ' /var/lib/inception/guest-image/manifest.json /run/inception/default-image-id
    '';
  };
  systemd.services.inception-database = oneshot [ "postgresql-setup.service" "inception-identity.service" ] ''
    exec ${prepare "database"}
  '';
  systemd.services.inception-migrate = oneshot [ "inception-database.service" "inception-environment.service" ] ''
    exec ${prepare "exec"} ${packages.marshall}/bin/marshall eval 'Marshall.Operations.Migrate.main()'
  '';
  systemd.services.inception-enrollment = (oneshot [ "inception-migrate.service" "inception-storage.service" "inception-image.service" ] ''
    export RELEASE_COOKIE RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
    ${packages.lilly}/bin/lilly eval 'Code.eval_file("${./probe.exs}")'
    ${operator ./enroll.exs}
  '') // { path = [ zfs "${packages.lilly}/host-tools" ]; };

  systemd.slices.lilly.sliceConfig = {
    CPUAccounting = true; MemoryAccounting = true; IOAccounting = true; TasksAccounting = true;
    CPUQuota = "1400%"; MemoryMax = "24G";
  };
  # @cc [owner:ghuntley,label:deployment;recovery] inception-independent-lilly-runtime
  # The inner provisioner MUST read its private, native-GUID-bound enrollment
  # configuration. Its daemon MUST remain outside the nested VMs' separate slice,
  # so restarting Lilly does not terminate those systemd-supervised VMMs.
  systemd.services.lilly = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-enrollment.service" "lilly.slice" ];
    after = [ "inception-enrollment.service" "lilly.slice" "marshall-inception.service" ];
    path = [ zfs "${packages.lilly}/host-tools" pkgs.systemd ];
    environment = {
      LILLY_CONFIG_FILE = "/var/lib/inception/lilly.json";
      LILLY_STATUS_SOCKET = "/run/lilly-release/status.sock";
      RELEASE_DISTRIBUTION = "none";
      RELEASE_TMP = "/run/lilly-release";
      ERL_CRASH_DUMP = "/dev/null";
    };
    script = ''
      export RELEASE_COOKIE
      RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
      exec ${packages.lilly}/bin/lilly start
    '';
    serviceConfig = {
      Type = "exec"; User = "root"; UMask = "0077";
      RuntimeDirectory = "lilly-release"; RuntimeDirectoryMode = "0700";
      Restart = "on-failure"; RestartSec = 5; LimitNOFILE = 65536;
      MemoryMax = "1G"; TasksMax = 4096;
    };
  };
  systemd.services.inception-enable = {
    requires = [ "lilly.service" "marshall-inception.service" ];
    after = [ "lilly.service" "marshall-inception.service" ];
    script = operator "${./.}/enable.exs";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
  };
  systemd.timers.inception-enable = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "15s"; OnUnitInactiveSec = "15s"; };
  };
  systemd.services.lilly-readiness.environment.LILLY_REQUIRED_UNITS =
    "inception-enable.service lilly.service marshall-inception.service postgresql.service";
}
