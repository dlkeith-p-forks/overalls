{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.overallsNixGc;
  description = "Collect bounded Nix store garbage below the free-space threshold";
  # The guest dataset quota is a ceiling, not a reservation: legitimate guest
  # growth can push pool free space below the threshold, where a run finds
  # nothing older than the preservation window to delete and exits.
  gcScript = ''
    set -euo pipefail

    readonly MIN_THRESHOLD_KIB="${toString (cfg.diskThresholdGiB * 1024 * 1024)}"
    readonly MAX_FREED_BYTES="${toString (cfg.maxFreedGiB * 1024 * 1024 * 1024)}"
    readonly AVAILABLE_KIB="$(${pkgs.coreutils}/bin/df --sync /nix --output=avail | ${pkgs.coreutils}/bin/tail -n1)"

    if [ "$AVAILABLE_KIB" -lt "$MIN_THRESHOLD_KIB" ]; then
      echo "Have $AVAILABLE_KIB KiB free on /nix, want at least $MIN_THRESHOLD_KIB KiB."
      echo "Collecting up to $MAX_FREED_BYTES of store paths older than ${cfg.preserveGenerations}."
      exec ${config.nix.package}/bin/nix-collect-garbage \
        --delete-older-than "${cfg.preserveGenerations}" \
        --max-freed "$MAX_FREED_BYTES"
    else
      echo "Skipping collection, $AVAILABLE_KIB KiB free on /nix."
    fi
  '';
in
{
  options.services.overallsNixGc = {
    enable = mkEnableOption "bounded automatic Nix store garbage collection";

    interval = mkOption {
      type = types.strMatching "[1-9][0-9]*(s|min|h)";
      default = "1h";
      description = ''
        Delay between garbage collection checks. The first check runs one
        interval after boot; missed checks are caught up after downtime.
      '';
    };

    diskThresholdGiB = mkOption {
      type = types.ints.positive;
      default = 100;
      description = ''
        Minimum free space in GiB on the filesystem holding /nix. Falling
        below it triggers a collection run.
      '';
    };

    maxFreedGiB = mkOption {
      type = types.ints.positive;
      default = 200;
      description = "Maximum space in GiB a single collection run may delete.";
    };

    preserveGenerations = mkOption {
      type = types.strMatching "[1-9][0-9]*[smhd]";
      default = "14d";
      description = ''
        Age passed to nix-collect-garbage --delete-older-than. Generations
        younger than this are preserved.
      '';
    };
  };

  config = mkIf cfg.enable {
    # @cc [owner:ghuntley,label:deployment] bounded-nix-store-reclamation
    # A run MUST execute only when free space on the filesystem holding /nix
    # is below the configured threshold, MUST delete at most maxFreedGiB and
    # MUST preserve generations younger than preserveGenerations. The service
    # and timer MUST NOT exist unless enabled and MUST use the configured
    # nix.package. Disabling the timer remains the documented manual-recovery
    # control; no additional in-script kill switch exists.
    systemd.services.overalls-nix-gc = {
      inherit description;
      script = gcScript;
      serviceConfig.Type = "oneshot";
    };

    systemd.timers.overalls-nix-gc = {
      inherit description;
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitInactiveSec = cfg.interval;
        RandomizedDelaySec = 300;
        Persistent = true;
      };
    };
  };
}
