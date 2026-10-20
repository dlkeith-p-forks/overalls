{ tribuchet, nixGrpcStore }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.fleetBuilds;
  nameType = types.strMatching "[a-z][a-z0-9-]{0,27}";
  addressType = types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  peers = lib.filterAttrs (name: _: name != cfg.localName) cfg.machines;
  local = cfg.machines.${cfg.localName} or (throw "Fleet builds require a registered localName.");
  scheduler = cfg.machines.${cfg.scheduler} or (throw "Fleet builds require a registered scheduler.");
  isScheduler = cfg.localName == cfg.scheduler;
  bundle = config.services.overallsSecrets.bundles.fleet-builds;
  secretFile = name: "${bundle.directory}/${name}";
  grpcCredential = "/run/credentials/nix-grpc-daemon.service/grpc.key";
  hubConfigDir = "/run/overalls-fleet-builds/tribuchet";
  # The client side of every grpc:// store runs in nix-daemon (root): the
  # substituter and the build hook both present this host's certificate from
  # the plugin's default /run/nix-grpc-store pair. Nix names a lock file after
  # each build machine URI, so store paths in the query overflow NAME_MAX.
  grpcCa = "/etc/nix-grpc-store/ca.crt";
  # A refused peer hands work back to the local daemon quickly instead of the
  # plugin's 30 s default retry per call.
  grpcQuery = "connect-timeout=5&ca-cert=${grpcCa}";
  grpcStore = machine: "grpc://${machine.address}:${toString cfg.grpcPort}";
  hubPort = 7437;
  hub = config.services.tribuchet-hub;
  # Tribuchet's shim fails a build outright when its hub socket refuses
  # connections. Decline instead: print Nix's builder ready marker, then exit
  # 222 (tribuchet's DECLINE_EXIT_CODE), so the patched Nix builds locally; an
  # exit before the marker is a setup failure. A listening socket whose hub is
  # restarting still accepts.
  attachOrDecline = pkgs.writeShellScript "tribuchet-attach-or-decline" ''
    if ! ${lib.getExe pkgs.socat} -u OPEN:/dev/null UNIX-CONNECT:${toString hub.socketPath} 2>/dev/null; then
      printf '\002\n' >&2
      exit 222
    fi
    exec ${lib.getExe' hub.package "tribuchet"} attach "$1" --socket ${toString hub.socketPath}
  '';
  systems = lib.unique (lib.concatMap (m: m.systems) (lib.attrValues cfg.machines));
in {
  imports = [ tribuchet.nixosModules.default nixGrpcStore.nixosModules.server nixGrpcStore.nixosModules.client ];

  options.overalls.fleetBuilds = {
    enable = lib.mkEnableOption "fleet build scheduling through a tribuchet hub and grpc:// stores";
    localName = mkOption { type = nameType; default = config.networking.hostName; };
    scheduler = mkOption { type = nameType; description = "The one participant running the tribuchet hub."; };
    grpcPort = mkOption { type = types.port; default = 50051; };
    tribuchetCaCertificate = mkOption { type = types.path; description = "Public tribuchet CA certificate."; };
    grpcCaCertificate = mkOption { type = types.path; description = "Public nix-grpc-store CA certificate."; };
    machines = mkOption {
      default = {};
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption { type = addressType; description = "Tailnet IPv4 address; the certificates' IP SAN."; };
          systems = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_-]+"); };
          logicalCpus = mkOption { type = types.ints.positive; };
          supportedFeatures = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_-]+"); default = []; };
          tribuchetCertificate = mkOption { type = types.path; description = "Public tribuchet worker certificate."; };
          tribuchetHubCertificate = mkOption { type = types.nullOr types.path; default = null; };
          grpcCertificate = mkOption { type = types.path; description = "Public grpc certificate, CN build-NAME."; };
          encryptedFile = mkOption { type = (import ./types.nix { inherit lib; }).absolutePath; };
        };
      });
    };
  };

  # @cc [owner:ghuntley,label:security;deployment] fleet-build-scheduling
  # Exactly one registered participant MUST run the tribuchet hub, and it MUST
  # NOT configure nix.buildMachines; the others MUST delegate only to that
  # scheduler's grpc:// store under its mTLS-pinned CA. Tribuchet workers only
  # import through their nix-daemon and never re-delegate, so no build cycle
  # exists (ADR-0248). Signature checking MUST remain enabled, and the hub and
  # grpc listeners MUST NOT be opened on any firewall interface beyond the
  # trusted tailnet.

  # @cc [owner:ghuntley,label:security] fleet-build-grpc-caches
  # Participants MUST substitute from each other over grpc:// with peer
  # certificates, granting read-only to peers and trusted only to the
  # non-scheduler delegating to the scheduler. Unmatched CNs MUST be denied.
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        { assertion = cfg.machines ? ${cfg.localName}; message = "Fleet builds require a registered localName."; }
        { assertion = cfg.machines ? ${cfg.scheduler}; message = "Fleet builds require a registered scheduler."; }
        { assertion = peers != {}; message = "Fleet builds require at least one peer."; }
        { assertion = lib.all nameType.check (lib.attrNames cfg.machines);
          message = "Fleet build participant names must be safe host identifiers."; }
        { assertion = lib.length (lib.unique (lib.mapAttrsToList (_: m: m.address) cfg.machines)) == lib.length (lib.attrNames cfg.machines);
          message = "Fleet build participant addresses must be distinct."; }
        { assertion = lib.all (m: m.systems != []) (lib.attrValues cfg.machines);
          message = "Fleet build participants require systems."; }
        { assertion = lib.length (lib.filter (m: m.tribuchetHubCertificate != null) (lib.attrValues cfg.machines)) == 1
            && scheduler.tribuchetHubCertificate != null;
          message = "Exactly the scheduler must carry a tribuchet hub certificate."; }
        { assertion = !isScheduler || config.nix.buildMachines == [];
          message = "The fleet build scheduler must not delegate builds."; }
        { assertion = config.nix.settings.require-sigs; message = "Fleet builds must preserve signature checking."; }
        { assertion = !(lib.elem hubPort config.networking.firewall.allowedTCPPorts)
            && !(lib.elem cfg.grpcPort config.networking.firewall.allowedTCPPorts);
          message = "Fleet build listeners must not be opened publicly."; }
      ];

      services.overallsSecrets = {
        enable = true;
        bundles.fleet-builds = {
          encryptedFile = local.encryptedFile;
          outputs = {
            "tribuchet-worker.key" = { format = "raw"; secrets = [ "TRIBUCHET_WORKER_KEY" ]; };
            "grpc.key" = { format = "raw"; secrets = [ "GRPC_KEY" ]; };
          } // lib.optionalAttrs isScheduler {
            "tribuchet-hub.key" = { format = "raw"; secrets = [ "TRIBUCHET_HUB_KEY" ]; };
          };
        };
      };
      # @cc [owner:ghuntley,label:recovery] fleet-build-credentials-optional-for-local-builds
      # Missing or failed fleet build credentials MUST NOT prevent local Nix
      # builds: nix-daemon only orders after the bundle.
      systemd.services.overalls-secrets-fleet-builds.wantedBy = [ "multi-user.target" ];
      systemd.services.nix-daemon = { wants = [ bundle.unit ]; after = [ bundle.unit ]; };

      # Every participant serves its store over grpc:// and runs a worker.
      services.nix-grpc-daemon = {
        enable = true;
        listen = "0.0.0.0:${toString cfg.grpcPort}";
        workerName = cfg.localName;
        maxJobs = 63;
        tls = {
          certFile = local.grpcCertificate;
          keyFile = grpcCredential;
          clientCaFile = cfg.grpcCaCertificate;
        };
        trustClients = isScheduler;
        accessRules = lib.mapAttrsToList (name: _: {
          cn = "build-${name}";
          role = if isScheduler then "trusted" else "read-only";
        }) peers;
      };
      systemd.services.nix-grpc-daemon = {
        wants = [ bundle.unit ];
        after = [ bundle.unit ];
        serviceConfig.LoadCredential = "grpc.key:${secretFile "grpc.key"}";
      };
      programs.nix-grpc-store.enable = true;
      environment.etc."nix-grpc-store/ca.crt".source = cfg.grpcCaCertificate;
      systemd.tmpfiles.rules = [
        "d /run/nix-grpc-store 0700 root root -"
        "L+ /run/nix-grpc-store/client.crt - - - - ${local.grpcCertificate}"
        "L+ /run/nix-grpc-store/client.key - - - - ${secretFile "grpc.key"}"
      ];
      overalls.remoteBuilders.substitutePeers = lib.mkIf config.overalls.remoteBuilders.enable
        (lib.filter (name: !(builtins.hasAttr name cfg.machines))
          (lib.attrNames (lib.filterAttrs (name: _: name != config.overalls.remoteBuilders.localName) config.overalls.remoteBuilders.machines)));
      nix.settings.substituters = lib.mapAttrsToList (_: machine: "${grpcStore machine}?trusted=true&${grpcQuery}&priority=50") peers;

      services.tribuchet-worker = {
        enable = true;
        keyFile = secretFile "tribuchet-worker.key";
        settings = {
          hub = "https://${scheduler.address}:${toString hubPort}";
          ca-cert = "${cfg.tribuchetCaCertificate}";
          cert = "${local.tribuchetCertificate}";
          systems = local.systems;
          max-jobs = local.logicalCpus;
        };
      };
      systemd.services.tribuchet-worker = { wants = [ bundle.unit ]; after = [ bundle.unit ]; };
    }

    (lib.mkIf isScheduler {
      services.tribuchet-hub = {
        enable = true;
        port = hubPort;
        openFirewall = false;
        configDir = hubConfigDir;
        settings.metrics-listen = "127.0.0.1:7438";
        externalBuilders = {
          enable = true;
          inherit systems;
          patchNix = true;
          # Stack tribuchet's patches on the compact-log Nix (ADR-0087).
          nixPackage = config.programs.nix-compact.package;
        };
      };
      # @cc [owner:ghuntley,label:recovery] fleet-build-hub-outage-local
      # An unreachable hub MUST NOT fail scheduler builds: they decline to
      # local execution.
      nix.settings.external-builders = lib.mkForce (builtins.toJSON [
        { inherit systems; program = attachOrDecline; args = []; }
      ]);
      systemd.tmpfiles.rules = [
        "d ${hubConfigDir}/ca 0700 root root -"
        "L+ ${hubConfigDir}/ca/ca.crt - - - - ${cfg.tribuchetCaCertificate}"
        "L+ ${hubConfigDir}/ca/hub.crt - - - - ${local.tribuchetHubCertificate}"
        "L+ ${hubConfigDir}/ca/hub.key - - - - ${secretFile "tribuchet-hub.key"}"
      ];
      systemd.services.tribuchet-hub = { wants = [ bundle.unit ]; after = [ bundle.unit ]; };
    })

    (lib.mkIf (!isScheduler) {
      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = map (system: {
        hostName = "${grpcStore scheduler}?system=${system}&${grpcQuery}";
        protocol = null;
        inherit system;
        supportedFeatures = scheduler.supportedFeatures;
        maxJobs = 2 * scheduler.logicalCpus;
      }) scheduler.systems;
    })
  ]);
}
