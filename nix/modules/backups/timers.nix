{ cfg }:
let
  # @cc [owner:ghuntley,label:capacity] backup-fleet-jitter
  # Scheduled backups MUST use a configurable stable randomized delay so hosts
  # do not all start PostgreSQL dumps and uploads at calendar boundaries.
  # Missed runs may catch up, but systemd MUST NOT launch parallel instances.
  timer = calendar: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      Persistent = true;
      RandomizedDelaySec = cfg.randomizedDelaySec;
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };
in {
  overalls-backup = timer cfg.schedule;
  overalls-backup-prune = timer "*-*-* 03:00:00";
  overalls-backup-check = timer "*-*-* 09:00:00";
  overalls-backup-read-check = timer "Sun *-*-* 15:00:00";
  overalls-backup-cleanup = timer "*-*-* *:0/5:00";
}
