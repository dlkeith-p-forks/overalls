{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsSecrets;
  localTypes = import ../types.nix { inherit lib; };
  tools = packages.secretTools;
  names = builtins.attrNames cfg.bundles;
  bundleSecrets = bundle: lib.unique (lib.concatMap (output: output.secrets) (builtins.attrValues bundle.outputs));
  manifest = name: bundle: (pkgs.formats.toml {}).generate "${name}-secretspec.toml" {
    project = { name = "overalls-${name}"; revision = "1.0"; };
    profiles.production = lib.genAttrs (bundleSecrets bundle) (_: {
      description = "Required deployment secret";
      required = true;
    });
  };
  serviceName = name: "overalls-secrets-${name}";
  runtime = name: "/run/${serviceName name}";
  descriptor = name: bundle: pkgs.writeText "${name}-secret-preparation.json" (builtins.toJSON {
    hostKey = "/etc/ssh/ssh_host_ed25519_key";
    runtime = runtime name;
    inherit (bundle) encryptedFile group outputs;
    destination = bundle.directory;
    manifest = "${manifest name bundle}";
    toolPath = lib.makeBinPath [ tools.sops ];
    sshToAge = "${tools.ssh-to-age}/bin/ssh-to-age";
    secretspec = "${tools.secretspec}/bin/secretspec";
  });
in
{
  imports = [ ../host-identity.nix ];
  options.services.overallsSecrets = {
    enable = mkEnableOption "SSH-derived age identities and direct SecretSpec/SOPS delivery";
    descriptors = mkOption {
      type = types.attrsOf types.path;
      readOnly = true;
      internal = true;
      default = if cfg.enable then lib.mapAttrs descriptor cfg.bundles else {};
      description = "Public preparation descriptors shared with candidate deployment staging.";
    };
    bundles = mkOption {
      default = {};
      description = "Separate SOPS documents and atomically published application bundles.";
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          encryptedFile = mkOption {
            type = localTypes.absolutePath;
            description = "Root-controlled SOPS-encrypted JSON or YAML document; no plaintext.";
          };
          group = mkOption {
            type = types.strMatching "[a-z_][a-z0-9_-]*";
            default = "root";
            description = "Read-only recipient group; root uses 0700/0600, other groups 0750/0640.";
          };
          directory = mkOption {
            type = types.str;
            readOnly = true;
            default = "/run/overalls-secrets/${name}";
            description = "Canonical runtime directory containing the complete published bundle.";
          };
          unit = mkOption {
            type = types.str;
            readOnly = true;
            default = "${serviceName name}.service";
            description = "Preparation dependency to add to a consumer's secretUnits.";
          };
          outputs = mkOption {
            description = "Files in this bundle; all selected secrets are required.";
            type = types.attrsOf (types.submodule {
              options = {
                format = mkOption {
                  type = types.enum [ "raw" "environment" ];
                  description = "Raw single secret, or a systemd EnvironmentFile of selected values.";
                };
                secrets = mkOption {
                  type = types.listOf (types.strMatching "[A-Z_][A-Z0-9_]*");
                  description = "SecretSpec names under project overalls-BUNDLE, profile production.";
                };
              };
            });
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}" name != null) names;
        message = "Secret bundle names must be safe identifiers."; }
      { assertion = lib.all (bundle:
          let outputs = builtins.attrValues bundle.outputs; in
          outputs != [] && builtins.length outputs <= 32 && builtins.length (bundleSecrets bundle) <= 64 &&
          lib.all (output: output.secrets != [] && (output.format != "raw" || builtins.length output.secrets == 1)) outputs &&
          lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}" name != null) (builtins.attrNames bundle.outputs)
        ) (builtins.attrValues cfg.bundles);
        message = "Secret bundles require 1..32 valid output files, at most 64 required secrets, and one secret per raw output."; }
      { assertion = lib.any (key: key.type == "ed25519" && key.path == "/etc/ssh/ssh_host_ed25519_key") config.services.openssh.hostKeys;
        message = "Secret preparation requires the persistent SSH Ed25519 host identity."; }
      { assertion = lib.all (bundle: builtins.hasAttr bundle.group config.users.groups) (builtins.attrValues cfg.bundles);
        message = "Every secret recipient group must be declared in users.groups."; }
    ];

    systemd.tmpfiles.rules = [ "d /run/overalls-secrets 0755 root root -" ];
    systemd.services = lib.mapAttrs' (name: bundle:
      let configuration = cfg.descriptors.${name};
      in lib.nameValuePair (serviceName name) {
        description = "Resolve the ${name} SecretSpec/SOPS bundle";
        after = [ "sshd-keygen.service" "systemd-tmpfiles-setup.service" ];
        requires = lib.optionals config.services.openssh.generateHostKeys [ "sshd-keygen.service" ];
        restartTriggers = [ configuration ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          Group = "root";
          UMask = "0077";
          RuntimeDirectory = serviceName name;
          RuntimeDirectoryMode = "0700";
          ExecStart = "${pkgs.python3}/bin/python ${./prepare.py} ${configuration}";
          ExecStopPost = "${pkgs.python3}/bin/python ${./prepare.py} --cleanup ${configuration}";
          TimeoutStartSec = 150;
          KillMode = "control-group";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateNetwork = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ "/run/overalls-secrets" ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      }) cfg.bundles;
  };
}
