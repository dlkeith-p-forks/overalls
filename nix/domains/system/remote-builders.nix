{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.remoteBuilders;
  nameType = types.strMatching "[a-z][a-z0-9-]{0,27}";
  keyType = types.strMatching "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}( [^\n\r]+)?";
  peers = lib.filterAttrs (name: _: name != cfg.localName) cfg.machines;
  local = cfg.machines.${cfg.localName} or null;
  alias = name: "overalls-builder-${name}";
  keyFile = "/run/overalls-secrets/remote-builders/id_ed25519";
  unit = "overalls-secrets-remote-builders.service";
  authorizedKeys = map (key: "restrict ${key}") (lib.concatMap (m: m.clientPublicKeys) (lib.attrValues peers));
  endpoint = name: "ssh-ng://nix-ssh@${alias name}";
in {
  options.overalls.remoteBuilders = {
    enable = lib.mkEnableOption "reciprocal pinned SSH caches with restricted machine access";
    localName = mkOption { type = nameType; default = config.networking.hostName; };
    substitutePeers = mkOption {
      type = types.listOf nameType;
      default = lib.attrNames peers;
      defaultText = lib.literalMD "every registered peer";
      description = "Peers used as ssh-ng substituters; fleet builds replace some with grpc:// (ADR-0248).";
    };
    machines = mkOption {
      default = {};
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption { type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*"; };
          port = mkOption { type = types.port; default = 22; };
          systems = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_-]+"); };
          logicalCpus = mkOption { type = types.ints.positive; };
          supportedFeatures = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_-]+"); default = []; };
          clientPublicKeys = mkOption { type = types.listOf keyType; };
          hostPublicKey = mkOption { type = keyType; };
          encryptedFile = mkOption { type = (import ./types.nix { inherit lib; }).absolutePath; };
        };
      });
    };
  };

  # @cc [owner:ghuntley,label:security] reciprocal-builder-trust
  # Only other registered machines may authenticate as nix-ssh. Their cache
  # trust MUST be scoped to strict inventory-pinned SSH endpoints; signature
  # verification and existing substituters/signing keys MUST remain enabled.

  # @cc [owner:ghuntley,label:deployment] no-peer-build-delegation
  # Peer machines MUST stay cache-only: the module MUST NOT delegate derivation
  # builds to fleet peers. Reciprocal build delegation forwards builds between
  # the peers' daemons and deadlocks concurrent host updates; see ADR-0086.
  # Fleet-build participants delegate only through fleet-builds.nix (ADR-0248).
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = !(builtins.hasAttr "nix-ssh" (config.overalls.access.users or {}));
        message = "nix-ssh is reserved for the restricted remote-builder account."; }
      { assertion = local != null; message = "Remote cache peers require a registered localName."; }
      { assertion = peers != {}; message = "Remote cache peers require at least one peer."; }
      { assertion = lib.all nameType.check (lib.attrNames cfg.machines);
        message = "Remote cache peer names must be safe host identifiers."; }
      { assertion = lib.all (machine: machine.systems != [] && machine.clientPublicKeys != []) (lib.attrValues cfg.machines);
        message = "Remote cache peers require systems and client keys."; }
      { assertion = lib.all (machine: machine.logicalCpus > 0) (lib.attrValues cfg.machines);
        message = "Remote cache peer logical CPU declarations must be positive."; }
      { assertion = lib.length (lib.unique (lib.mapAttrsToList (_: m: "${m.address}:${toString m.port}") cfg.machines)) == lib.length (lib.attrNames cfg.machines);
        message = "Remote cache peer endpoints must be distinct."; }
      { assertion = config.nix.settings.require-sigs; message = "Remote cache peers must preserve signature checking."; }
    ];
    nix = {
      settings = {
        require-sigs = true;
        fallback = true;
        substituters = lib.mapAttrsToList (name: _: "${endpoint name}?trusted=true&ssh-key=${keyFile}&priority=50")
          (lib.filterAttrs (name: _: builtins.elem name cfg.substitutePeers) peers);
      };
      sshServe = {
        enable = true;
        protocol = "ssh-ng";
        write = true;
        trusted = true;
        keys = authorizedKeys;
      };
    };
    users.users.nix-ssh.openssh.authorizedKeys = {
      keys = lib.mkForce authorizedKeys;
      keyFiles = lib.mkForce [];
    };
    # The upstream module forces nix-daemon --stdio and denies shell/PTY use.
    # DisableForwarding also covers Unix-domain socket forwarding.
    services.openssh.extraConfig = ''
      Match User nix-ssh
        AuthenticationMethods publickey
        PasswordAuthentication no
        DisableForwarding yes
        PermitUserRC no
      Match All
    '';
    programs.ssh.extraConfig = lib.concatStrings (lib.mapAttrsToList (name: machine: ''
      Host ${alias name}
        HostName ${machine.address}
        Port ${toString machine.port}
        User nix-ssh
        IdentityFile ${keyFile}
        IdentitiesOnly yes
        IdentityAgent none
        BatchMode yes
        StrictHostKeyChecking yes
        HostKeyAlias ${alias name}
        UserKnownHostsFile /etc/ssh/overalls-builders-known-hosts
        GlobalKnownHostsFile /dev/null
        ConnectTimeout 5
        ConnectionAttempts 1
        ServerAliveInterval 5
        ServerAliveCountMax 2
    '') peers);
    environment.etc."ssh/overalls-builders-known-hosts".text = lib.concatStrings (lib.mapAttrsToList (name: machine:
      "${alias name} ${machine.hostPublicKey}\n") peers);
    services.overallsSecrets = {
      enable = true;
      bundles.remote-builders = {
        encryptedFile = if local == null then "/invalid-local-machine" else local.encryptedFile;
        outputs.id_ed25519 = { format = "raw"; secrets = [ "SSH_PRIVATE_KEY" ]; };
      };
    };
    # @cc [owner:ghuntley,label:recovery] remote-key-optional-for-local-builds
    # Preparation failure MUST NOT prevent local Nix builds. Rotation MUST use
    # the updater's secret-consumer lifecycle and root-only bundle publication.
    systemd.services.overalls-secrets-remote-builders.wantedBy = [ "multi-user.target" ];
    systemd.services.nix-daemon = {
      wants = [ unit ];
      after = [ unit ];
      partOf = [ unit ];
    };
  };
}
