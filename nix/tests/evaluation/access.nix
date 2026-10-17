{ pkgs, nixpkgs, accessModule, secretsModule }:
let
  inherit (pkgs) lib;
  key = builtins.head (import ../../users.nix).ghuntley.sshKeys;
  evaluate = settings: (nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ accessModule secretsModule {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } settings ];
  }).config;
  cfg = evaluate {
    overalls.access = {
      enable = true;
      users = lib.mkForce {
        admin = { sshKeys = [ key ]; login = true; admin = true; };
        reader = { sshKeys = [ key ]; login = true; group = "readers"; extraGroups = [ "reports" ]; };
        recovery = { sshKeys = [ key ]; secretRecovery = true; };
        disabled = {};
      };
    };
  };
  valid = value: lib.all (item: item.assertion) value.assertions;
  invalid = users: !valid (evaluate { overalls.access = { enable = true; users = lib.mkForce users; }; });
  onlySecrets = evaluate { services.overallsSecrets.enable = true; };
  disabled = evaluate {};
  combined = evaluate { services.overallsSecrets.enable = true; overalls.access.enable = true; };
  cases = {
    valid = valid cfg;
    immutable = !cfg.users.mutableUsers;
    login-users-linger = cfg.users.users.admin.linger && cfg.users.users.reader.linger;
    mosh-enabled = cfg.programs.mosh.enable && cfg.programs.mosh.openFirewall;
    mosh-ports = builtins.elem { from = 60000; to = 61000; } cfg.networking.firewall.allowedUDPPortRanges;
    no-implicit-mosh = !disabled.programs.mosh.enable && !onlySecrets.programs.mosh.enable
      && disabled.networking.firewall.allowedUDPPortRanges == []
      && onlySecrets.networking.firewall.allowedUDPPortRanges == [];
    named-only = cfg.services.openssh.settings.AllowUsers == [ "admin" "reader" ];
    no-root = cfg.services.openssh.settings.PermitRootLogin == "no";
    central-keys = cfg.services.openssh.authorizedKeysFiles == [ "/etc/ssh/authorized_keys.d/%u" ];
    reader-groups = cfg.users.users.reader.group == "readers" && cfg.users.users.reader.extraGroups == [ "reports" ];
    groups-declared = cfg.users.groups ? readers && cfg.users.groups ? reports;
    recovery-no-account = !(cfg.users.users ? recovery) && !(cfg.users.users ? disabled);
    admin-sudo = lib.any (rule: rule.users == [ "admin" ] &&
      lib.any (command: command.command == "ALL" && builtins.elem "NOPASSWD" command.options) rule.commands) cfg.security.sudo.extraRules;
    no-implicit-login = !onlySecrets.services.openssh.enable && onlySecrets.services.openssh.generateHostKeys;
    shared-host-identity = builtins.length combined.services.openssh.hostKeys == 1;
    no-admin-rejected = invalid { reader = { login = true; sshKeys = [ key ]; }; };
    missing-keys-rejected = invalid { admin = { login = true; admin = true; }; };
    recovery-admin-rejected = invalid { admin = { admin = true; secretRecovery = true; sshKeys = [ key ]; }; };
    root-rejected = invalid { root = { login = true; admin = true; sshKeys = [ key ]; }; };
  };
in
assert lib.assertMsg (lib.all (value: value) (lib.attrValues cases)) "Fleet access evaluation failed.";
pkgs.writeText "overalls-access-evaluation.json" (builtins.toJSON cases)
