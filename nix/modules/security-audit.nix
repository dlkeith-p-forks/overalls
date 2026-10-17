{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsSecurityAudit;
  paths = import ./types.nix { inherit lib; };
  architectures = [ "b64" ] ++ lib.optional pkgs.stdenv.hostPlatform.isx86_64 "b32";
  rules = arch: map (entry: "-a always,exit -F arch=${arch} -S ${entry.calls} -k ${entry.key}") [
    { calls = "execve,execveat"; key = "process_exec"; }
    { calls = "sethostname,setdomainname"; key = "network"; }
    { calls = "adjtimex,settimeofday,clock_settime"; key = "time_change"; }
    { calls = "ptrace"; key = "injection"; }
    { calls = "chmod,fchmod,fchmodat"; key = "file_permissions"; }
    { calls = "chown,fchown,lchown,fchownat"; key = "file_ownership"; }
    { calls = "init_module,finit_module,delete_module"; key = "modules"; }
    { calls = "mount,umount2"; key = "mount"; }
  ];
  watches = [ "/etc" "/root/.ssh" "/run/overalls-secrets" ] ++ cfg.extraWatchPaths
    ++ lib.optionals (config.services.lilly.enable or false)
      [ config.services.lilly.stateDirectory config.services.lilly.vmStateDirectory ];
  watchScript = pkgs.writeShellScript "overalls-audit-watches" (lib.concatMapStrings (path: ''
    if [ -d ${lib.escapeShellArg path} ]; then
      ${pkgs.audit}/bin/auditctl -w ${lib.escapeShellArg path} -p ${if path == "/run/overalls-secrets" || path == "/root/.ssh" then "rwxa" else "wa"} -k overalls_state >/dev/null
    fi
  '') watches);
in {
  # @cc [owner:ghuntley,label:security] audit-explicit-restricted-evidence
  # Full exec argument capture MUST remain opt-in and restricted under ADR-0042.
  # Rules MUST NOT audit guest disk I/O or make audit failure halt running guests.
  options.services.overallsSecurityAudit = {
    enable = mkEnableOption "restricted host audit evidence including command arguments";
    extraWatchPaths = mkOption { type = types.listOf paths.absolutePath; default = []; description = "Existing administrative directories; never guest disk trees."; };
  };
  config = mkIf cfg.enable {
    security.audit = {
      enable = true; failureMode = "printk"; backlogLimit = 65536; rateLimit = 0;
      rules = lib.concatMap rules architectures;
    };
    security.auditd = {
      enable = true;
      settings = {
        log_group = "root"; max_log_file = 128; num_logs = 8;
        max_log_file_action = "ROTATE";
        space_left_action = "SYSLOG"; admin_space_left_action = "SUSPEND";
        disk_full_action = "SUSPEND"; disk_error_action = "SYSLOG";
      };
    };
    # auditd is the sole raw audit reader; do not duplicate into the journal.
    systemd.sockets.systemd-journald-audit.enable = false;
    systemd.tmpfiles.rules = [ "d /run/overalls-secrets 0700 root root -" "d /var/log/audit 0700 root root -" ];
    systemd.services.overalls-audit-watches = {
      wantedBy = [ "multi-user.target" ];
      after = [ "auditd.service" "systemd-tmpfiles-setup.service" "local-fs.target" ];
      requires = [ "auditd.service" ];
      before = [ "lilly.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = watchScript; ExecReload = watchScript; };
    };
  };
}
