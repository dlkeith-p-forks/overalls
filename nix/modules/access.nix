{ config, lib, ... }:
let
  cfg = config.overalls.access;
  registry = import ../lib/registry.nix { inherit lib; };
  logins = lib.filterAttrs (_: user: user.login) cfg.users;
  admins = lib.attrNames (lib.filterAttrs (_: user: user.admin) logins);
  groups = lib.unique (lib.concatMap (user: [ user.group ] ++ user.extraGroups) (lib.attrValues logins));
in
{
  imports = [ ./host-identity.nix ];
  options.overalls.access = {
    enable = lib.mkEnableOption "authoritative named fleet SSH access";
    users = lib.mkOption {
      type = registry.usersType;
      default = import ../users.nix;
      description = "Shared public user registry; permissions are explicit and fleet-wide.";
    };
  };
  config = lib.mkIf cfg.enable {
    # @cc [owner:ghuntley,label:security] fleet-host-mosh
    # Fleet access MUST enable Mosh. Standalone access opens its standard UDP
    # range; the fleet firewall may replace that public grant with its stricter
    # trusted-interface and reviewed-source policy. Guest access is separate.
    programs.mosh.enable = true;

    assertions = [
      { assertion = registry.validUsers cfg.users; message = "Fleet users need valid non-root names, keys for permissions, and login for admin."; }
      { assertion = admins != []; message = "Fleet SSH access requires at least one keyed administrator."; }
      { assertion = config.services.openssh.authorizedKeysCommand == "none";
        message = "Fleet access forbids alternate authorized-key commands."; }
      { assertion = (config.services.openssh.settings.TrustedUserCAKeys or null) == null;
        message = "Fleet access forbids alternate SSH certificate authorities."; }
    ];

    # @cc [owner:ghuntley,label:security] authoritative-human-access
    # Only registry login users and their declared keys may authenticate over SSH,
    # except the remote-builders module's forced-command nix-ssh account.
    # Removing accounts, keys or memberships MUST revoke them on activation;
    # existing sessions and preserved home data are outside this revocation boundary.
    users.mutableUsers = lib.mkForce false;
    users.groups = lib.genAttrs groups (_: {});
    users.users = lib.mapAttrs (_: user: {
      isNormalUser = true;
      # @cc [owner:ghuntley,label:deployment] fleet-user-lingering
      # Every registry login account MUST have a persistent systemd user manager
      # independent of interactive login sessions.
      linger = true;
      group = lib.mkForce user.group;
      extraGroups = lib.mkForce (lib.unique (user.extraGroups ++ lib.optional user.admin "wheel"));
      hashedPassword = lib.mkForce "!";
      openssh.authorizedKeys = {
        keys = lib.mkForce user.sshKeys;
        keyFiles = lib.mkForce [];
      };
    }) logins;
    security.sudo.enable = true;
    security.sudo.extraRules = [{
      users = admins;
      commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
    }];
    services.openssh = {
      enable = true;
      authorizedKeysInHomedir = lib.mkForce false;
      authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
      settings = {
        AllowUsers = lib.mkForce (lib.attrNames logins ++ lib.optional (config.overalls.remoteBuilders.enable or false) "nix-ssh");
        PermitRootLogin = lib.mkForce "no";
        PasswordAuthentication = lib.mkForce false;
        KbdInteractiveAuthentication = lib.mkForce false;
        AuthenticationMethods = lib.mkForce "publickey";
      };
    };
  };
}
