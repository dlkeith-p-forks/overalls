{ pkgs, packages }:
let
  lock = builtins.fromJSON (builtins.readFile ../../packages/guest/ubuntu/packages.lock.json);
  withoutDependency = lock // {
    packages = builtins.filter (entry: entry.name != "libpython3.14-stdlib") lock.packages;
  };
  withoutRequested = lock // {
    packages = builtins.filter (entry: entry.name != "curl") lock.packages;
  };
  # @cc [owner:ghuntley,label:verification] ubuntu-offline-refusal-reason
  # Negative checks MUST execute the real image builder and require the expected
  # APT refusal, read from the builder's host-visible exchange-directory
  # transcript or the captured console. An unrelated VM/build failure MUST NOT
  # count as a passing test.
  failure = name: value: message:
    let
      image = packages.mkUbuntuGuest {
        imageName = name;
        packageLock = builtins.toFile "${name}.json" (builtins.toJSON value);
      };
      wrapper = pkgs.writeShellScript "expect-ubuntu-build-refusal" ''
        export PATH=${pkgs.coreutils}/bin
        source "$NIX_ATTRS_SH_FILE"
        out="''${outputs[out]}"
        set +e
        "$@" > build.log 2>&1
        status=$?
        set -e
        # The VM teardown after a failed build script can race the exchange
        # directory's visibility; wait briefly for the APT transcript.
        attempt=0
        while test "$attempt" -lt 10 && ! test -s xchg/apt.log; do
          sleep 1
          attempt=$((attempt + 1))
        done
        observed=fail
        if test -s xchg/apt.log && ${pkgs.gnugrep}/bin/grep -F ${pkgs.lib.escapeShellArg message} xchg/apt.log; then
          observed=ok
        elif ${pkgs.gnugrep}/bin/grep -F ${pkgs.lib.escapeShellArg message} build.log; then
          observed=ok
        fi
        if test "$status" = 0 || test "$observed" != ok; then
          echo "Expected offline APT refusal was not observed" >&2
          echo "--- xchg/apt.log (if any):" >&2
          tail -20 xchg/apt.log >&2 || true
          echo "--- build.log tail:" >&2
          tail -100 build.log >&2
          exit 1
        fi
        touch "$out"
      '';
    in pkgs.lib.overrideDerivation image.rootfs (original: {
      builder = "${pkgs.bash}/bin/bash";
      args = [ wrapper original.builder ] ++ original.args;
    });
in
pkgs.linkFarm "ubuntu-build-boundaries" [
  { name = "missing-dependency"; path = failure "ubuntu-missing-dependency" withoutDependency "Depends: libpython3.14-stdlib"; }
  { name = "missing-request"; path = failure "ubuntu-missing-request" withoutRequested "E: Package 'curl' has no installation candidate"; }
]
