{ lib, checks }:
let
  # @cc [owner:ghuntley,label:verification] ci-check-selection
  # Every exported check MUST carry `meta.ci` so GitHub Actions derives its
  # matrices by evaluation rather than a hand-maintained list. A check is
  # excluded from CI only by name here, never by omission from the catalog.
  excluded = [
    # Inception guest workloads are outside CI; the guest-inception package
    # does not currently evaluate.
    "inception"
    "inception-runtime"
    "inception-ssh-host-ca"
    "inception-image-builder"
    "inception-probe"
    "inception-proof-broker"
  ];

  # Checks that run NixOS machine tests without being one themselves.
  machineAggregates = [ "host-conversion" ];

  features = check: check.requiredSystemFeatures or [ ];

  ciMeta = name: check: {
    enable = !(builtins.elem name excluded);
    machine = check ? driver || builtins.elem "kvm" (features check)
      || builtins.elem name machineAggregates;
    nestedKvm = builtins.elem "nested-kvm" (features check);
  };
in
lib.mapAttrs (name: check:
  check // { meta = (check.meta or { }) // { ci = ciMeta name check; }; }
) checks
