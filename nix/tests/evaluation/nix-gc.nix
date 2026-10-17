{ pkgs, nixpkgs, module, fixtures }:
let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  disabled = evaluate {};
  enabled = evaluate { services.overallsNixGc.enable = true; };
  tuned = evaluate {
    services.overallsNixGc = {
      enable = true;
      interval = "30min";
      diskThresholdGiB = 200;
      maxFreedGiB = 400;
      preserveGenerations = "30d";
    };
  };
  script = tuned.systemd.services.overalls-nix-gc.script;
  rejected = value: !(builtins.tryEval (builtins.deepSeq
    (evaluate { services.overallsNixGc = { enable = true; } // value; }).services.overallsNixGc true)).success;

  # @cc [owner:ghuntley,label:verification] nix-gc-configuration-check
  # These checks MUST exercise the real module assertions/types and the
  # production profile, without substituting service packages.
  cases = {
    optIn = !(disabled.systemd.services ? overalls-nix-gc)
      && !(disabled.systemd.timers ? overalls-nix-gc);
    emission = enabled.systemd.services.overalls-nix-gc.serviceConfig.Type == "oneshot"
      && enabled.systemd.timers.overalls-nix-gc.wantedBy == [ "timers.target" ]
      && enabled.systemd.timers.overalls-nix-gc.timerConfig.OnBootSec == "1h"
      && enabled.systemd.timers.overalls-nix-gc.timerConfig.OnUnitInactiveSec == "1h"
      && enabled.systemd.timers.overalls-nix-gc.timerConfig.RandomizedDelaySec == 300
      && enabled.systemd.timers.overalls-nix-gc.timerConfig.Persistent;
    thresholdGate = lib.hasInfix "df --sync /nix --output=avail" script
      && lib.hasInfix "tail -n1" script
      && lib.hasInfix "MIN_THRESHOLD_KIB=\"209715200\"" script
      && lib.hasInfix "MAX_FREED_BYTES=\"429496729600\"" script;
    boundedRun = lib.hasInfix "--delete-older-than \"30d\"" script
      && lib.hasInfix "--max-freed \"$MAX_FREED_BYTES\"" script;
    pinnedNix = lib.hasInfix "${tuned.nix.package.name}/bin/nix-collect-garbage" script;
    intervalRejected = lib.all rejected [ { interval = "0s"; } { interval = "1w"; } { interval = ""; } ];
    sizesRejected = lib.all rejected
      [ { diskThresholdGiB = 0; } { diskThresholdGiB = -1; } { diskThresholdGiB = "100"; } { maxFreedGiB = 0; } ];
    preservationRejected = lib.all rejected
      [ { preserveGenerations = "90 days"; } { preserveGenerations = "forever"; } ];
    fleetDefault = lib.all (name:
      fixtures.${name}.config.services.overallsNixGc.enable
      && fixtures.${name}.config.systemd.timers ? overalls-nix-gc
      && lib.all (a: a.assertion) fixtures.${name}.config.assertions)
      (builtins.attrNames fixtures);
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == []) "Nix store garbage collection checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-nix-gc-check.json" (builtins.toJSON cases)
