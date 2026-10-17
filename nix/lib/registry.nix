{ lib }:
let
  inherit (lib) types mkOption;
  nameType = types.strMatching "[a-z_][a-z0-9_-]{0,31}";
  keyType = types.strMatching "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}( [^\n\r]+)?";
  userType = types.submodule {
    options = {
      sshKeys = mkOption { type = types.listOf keyType; default = []; description = "Pinned public Ed25519 keys for SSH and optional recovery."; };
      login = mkOption { type = types.bool; default = false; description = "Create a named SSH account on every participating host."; };
      group = mkOption { type = nameType; default = "users"; description = "Primary Unix group."; };
      extraGroups = mkOption { type = types.listOf nameType; default = []; description = "Supplementary Unix groups."; };
      admin = mkOption { type = types.bool; default = false; description = "Grant this login user passwordless sudo."; };
      secretRecovery = mkOption { type = types.bool; default = false; description = "Include these keys in every managed encrypted document."; };
    };
  };
  usersType = types.attrsOf userType;
  inventoryType = types.submodule {
    options = {
      hosts = mkOption {
        default = {};
        type = types.attrsOf (types.submodule {
          options.sshKeys = mkOption { type = types.listOf keyType; description = "Authenticated public host keys; overlap during rotation."; };
        });
      };
      documents = mkOption {
        default = {};
        type = types.attrsOf (types.submodule {
          options = {
            path = mkOption { type = types.strMatching "secrets/[a-zA-Z0-9_./-]+\\.enc\\.(json|yaml|yml)"; description = "Repository-relative encrypted file."; };
            hosts = mkOption { type = types.listOf nameType; description = "Hosts authorized to decrypt this document."; };
            recoveryOnly = mkOption { type = types.bool; default = false; description = "Explicit recovery-only document; requires an empty host list and at least one recovery user."; };
          };
        });
      };
    };
  };
  validUsers = users: lib.all (name:
    let user = users.${name}; in
    nameType.check name && name != "root" && (!user.admin || user.login)
    && (!(user.login || user.secretRecovery) || user.sshKeys != [])
  ) (builtins.attrNames users);
  normalize = users: inventory:
    let result = (lib.evalModules {
      modules = [{
        options.users = mkOption { type = usersType; };
        options.inventory = mkOption { type = inventoryType; };
        config = { inherit users inventory; };
      }];
    }).config;
    in assert lib.assertMsg (validUsers result.users) "Invalid fleet user: require a valid non-root name, keys for permissions, and login for admin.";
      result;
in
{ inherit usersType inventoryType validUsers normalize; }
