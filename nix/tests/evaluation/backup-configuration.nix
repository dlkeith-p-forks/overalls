{ pkgs, module }:
let
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      networking.hostName = "fixture";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  configured = {
    services.overallsBackups = {
      enable = true;
      s3 = { endpoint = "https://objects.example.test"; bucket = "recovery"; region = "test-1"; };
    };
  };
  disabled = evaluate {};
  enabled = evaluate configured;
  custom = evaluate { imports = [ configured ]; services.overallsBackups.randomizedDelaySec = 73; };
  timer = enabled.systemd.timers.overalls-backup.timerConfig;
  cleanup = enabled.systemd.services.overalls-backup-cleanup;
  privateRejected = !(builtins.tryEval ((evaluate {
    imports = [ configured ];
    services.overallsBackups.passwordFile = "/nix/store/plaintext-password";
  }).services.overallsBackups.passwordFile)).success;
in
assert !(disabled.systemd.services ? overalls-backup);
assert timer.OnCalendar == "*-*-* *:00,30:00";
assert timer.RandomizedDelaySec == 300 && timer.FixedRandomDelay && timer.Persistent;
assert custom.systemd.timers.overalls-backup.timerConfig.RandomizedDelaySec == 73;
assert enabled.services.overallsBackups.retention.keepLast == 12;
assert cleanup.requires == [] && cleanup.serviceConfig.EnvironmentFile == [];
assert enabled.systemd.services.overalls-backup.serviceConfig.PrivateMounts;
assert enabled.systemd.services.overalls-backup.serviceConfig.KillMode == "control-group";
assert privateRejected;
pkgs.runCommand "overalls-backup-configuration" {} "touch $out"
