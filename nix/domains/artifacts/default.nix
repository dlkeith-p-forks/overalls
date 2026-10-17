{ pkgs, encryptedCrashDumps ? false, privateServiceRoots ? [ ], antithesisSdk ? false, antithesisGuest ? false, antithesisIntegratedHost ? false }:
assert !antithesisGuest || antithesisSdk;
assert !antithesisIntegratedHost || antithesisGuest;
let
  secretPackages = import ./secrets { inherit pkgs; };
  inherit (pkgs) lib;
  toolchain = import ./infrastructure/toolchain.nix { inherit pkgs encryptedCrashDumps; };
  # Build tools use the same pinned OTP without requiring a diagnostic key.
  # Only the shipped runtime needs encryption; Rebar never becomes release ERTS.
  plainToolchain = import ./infrastructure/toolchain.nix { inherit pkgs; };
  plainBeam = pkgs.beamMinimal29Packages.overrideScope (_final: _previous: {
    inherit (plainToolchain) erlang elixir;
  });
  beam = pkgs.beamMinimal29Packages.overrideScope (_final: _previous: {
    inherit (toolchain) erlang elixir;
  } // lib.optionalAttrs encryptedCrashDumps {
    inherit (plainBeam) rebar rebar3 hex;
  });
  hashes = builtins.fromJSON (builtins.readFile ./dependency-hashes.json);
  source = application: import ./applications/source.nix { inherit lib application antithesisSdk; };
  version = "0.1.0";
  hostLock = import ./hosts/host-tools.nix { inherit pkgs; };
  terminald = import ./infrastructure/terminald.nix { inherit pkgs; };
  terminaldChecks = import ./infrastructure/terminald-checks.nix { inherit pkgs; };
  codingClis = import ./guest/coding-clis.nix { inherit pkgs; };
  # Patched static Firecracker/jailer pair (ADR-0169); the only VMM Lilly runs.
  inherit (import ./infrastructure/firecracker.nix { inherit pkgs; }) vmm;
  # UEFI firmware Firecracker loads as its PVH "kernel" for Windows guests.
  windowsFirmware = import ./guest/windows/firmware.nix { inherit pkgs; };
  # DEBUG build with firmware tracing on the serial console, for boot diagnosis.
  windowsFirmwareDebug = import ./guest/windows/firmware.nix { inherit pkgs; debug = true; };
  mkWindowsGuest = import ./guest/windows { inherit pkgs; firmware = windowsFirmware; };
  # Agentless image (ADR-0170) carrying the vsock transport probe (ADR-0171 gate 1).
  windowsGuest = mkWindowsGuest { agents = lyraWindows; };
  # The windows-v1 image: the same installation with the readiness and trust
  # daemons declared in its manifest (ADR-0171 gate 2).
  windowsGuestAgents = mkWindowsGuest { agents = lyraWindows; terminald = terminaldWindows; guestAgents = "windows-v1"; };
  # Variant that loads the virtio storage driver with drvload instead of the
  # answer file's DriverPaths; kept for diagnosing Setup's WinPE initialization.
  windowsGuestDrvload = mkWindowsGuest { winpeDriverLoad = "drvload"; };
  windowsBoot = import ./guest/windows/boot.nix { inherit pkgs vmm; };
  lyra = import ./infrastructure/lyra.nix { inherit pkgs; };
  lyraWindows = lyra.windows;
  nativeAgentPayload = import ./guest/native-agents.nix { inherit pkgs lyra terminald; };
  # Native guest daemons use each OS's reviewed vsock ABI and are shipped
  # separately from the workstation CLI for native image assembly.
  lyraNative = pkgs.runCommand "overalls-native-agents" {} ''
    mkdir -p "$out/freebsd" "$out/illumos"
    cp -a ${nativeAgentPayload.freebsd}/. "$out/freebsd/"
    cp -a ${nativeAgentPayload.illumos}/. "$out/illumos/"
    cp ${lyra.native}/manifest.json "$out/lyra-manifest.json"
    cp ${terminald.native}/manifest.json "$out/terminald-manifest.json"
  '';
  # ConPTY terminal daemon for windows-v1 guests (ADR-0171 gate 4).
  terminaldWindows = import ./infrastructure/terminald-windows.nix { inherit pkgs; inherit (lyra) toolchain; };
  lyraLinux = pkgs.runCommand "overalls-linux-cli" {} ''
    mkdir -p "$out/bin"
    cp ${lyra}/bin/linux-amd64 "$out/bin/overalls"
    cp ${lyra}/bin/overalls-ssh-authorize "$out/bin/overalls-ssh-authorize"
    cp ${lyra}/bin/overalls-host-certificate "$out/bin/overalls-host-certificate"
    cp ${lyra}/bin/overalls-trustd "$out/bin/overalls-trustd"
    cp ${lyra}/bin/overalls-workspaced "$out/bin/overalls-workspaced"
    chmod 0755 "$out/bin/overalls" "$out/bin/overalls-ssh-authorize" "$out/bin/overalls-trustd" "$out/bin/overalls-host-certificate" "$out/bin/overalls-workspaced"
  '';
  hostTools = pkgs.buildEnv {
    name = "lilly-host-tools";
    paths = [
      pkgs.coreutils pkgs.diffutils pkgs.util-linux pkgs.iproute2 pkgs.nftables pkgs.procps
      pkgs.zfs pkgs.openssh toolchain.elixir toolchain.erlang hostLock
    ];
  };

  nestingProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis;
    privateServiceRoots = [ ];
    imageName = "inception-inner-nesting-probe-x86_64";
    minimumMemoryBytes = 536870912;
    extraModules = [ ./guest/nesting-probe/minimal.nix ];
  };

  # @cc [owner:ghuntley,label:build] release-dependency-hashes
  # Mix dependency fetches MUST be fixed-output derivations checked against
  # reviewed hashes; the normal release build MUST run with Hex offline.

  # @cc [owner:ghuntley,label:build] harness-dependency-selection
  # Fixed-output Mix dependency fetches and release compilation MUST use the
  # same explicit harness/guest/integrated-host selectors and production Mix
  # environment.
  dependencies = lib.genAttrs [ "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" ] (application:
    beam.fetchMixDeps {
      pname = "overalls-${application}-deps";
      inherit version;
      src = source application;
      sourceRoot = "source/${application}";
      hash = hashes.${application};
      env = {
        ERL_FLAGS = "+S 4:4";
        ERL_CRASH_DUMP_PUBLIC_KEY = if encryptedCrashDumps then "${./build-crash-dump-public.pem}" else "";
      } // lib.optionalAttrs antithesisSdk {
        ANTITHESIS_HARNESS = "1";
        MIX_ENV = "prod";
      } // lib.optionalAttrs (antithesisGuest && application == "lilly") {
        ANTITHESIS_GUEST = "1";
      } // lib.optionalAttrs (antithesisIntegratedHost && application == "lilly") {
        ANTITHESIS_INTEGRATED_HOST = "1";
      };
      postInstall = ''
        cp mix.lock "$out/.overalls-mix.lock"
      '';
    });

  cedarCargo = pkgs.rustPlatform.fetchCargoVendor {
    name = "marshall-cedar";
    src = "${dependencies.marshall}/ex_cedar/native/ex_cedar_native";
    hash = hashes.cedarCargo;
  };

  release = application:
    let
      isMarshall = application == "marshall";
      isLilly = application == "lilly";
      metadata = pkgs.writeText "${application}-release.json" (builtins.toJSON ({
        format = 1;
        inherit application;
        platform = pkgs.stdenv.hostPlatform.system;
        elixir = toolchain.elixir.version;
        otp = toolchain.erlang.version;
        build = "nix-source";
        encrypted_crash_dumps = encryptedCrashDumps;
      } // lib.optionalAttrs antithesisSdk {
        antithesis_sdk = true;
        antithesis_guest = antithesisGuest && isLilly;
        antithesis_integrated_host = antithesisIntegratedHost && isLilly;
      } // lib.optionalAttrs isLilly {
        host_tools = "${hostTools}";
        firecracker = "${vmm}/bin/firecracker";
        jailer = "${vmm}/bin/jailer";
        unshare = "${pkgs.util-linux.bin}/bin/unshare";
      }));
    in
    beam.mixRelease {
      pname = "overalls-${application}";
      inherit version;
      src = source application;
      sourceRoot = "source/${application}";
      mixFodDeps = dependencies.${application};
      compileFlags = [ "--warnings-as-errors" ];
      nativeBuildInputs = lib.optionals isMarshall [ pkgs.cargo pkgs.rustc pkgs.pkg-config ];
      env = {
        ERL_CRASH_DUMP_PUBLIC_KEY = if encryptedCrashDumps then "${./build-crash-dump-public.pem}" else "";
        ERL_FLAGS = "+S 4:4";
      } // lib.optionalAttrs antithesisSdk {
        ANTITHESIS_HARNESS = "1";
        MIX_ENV = "prod";
      } // lib.optionalAttrs (antithesisGuest && application == "lilly") {
        ANTITHESIS_GUEST = "1";
      } // lib.optionalAttrs (antithesisIntegratedHost && application == "lilly") {
        ANTITHESIS_INTEGRATED_HOST = "1";
      } // lib.optionalAttrs isMarshall {
        EX_CEDAR_BUILD = "1";
        CARGO_NET_OFFLINE = "true";
        CARGO_BUILD_JOBS = "4";
      };

      # @cc [owner:ghuntley,label:build] cedar-and-assets-prefetched
      # Compilation MUST use the vendored Cedar lockfile and pinned Nix asset
      # executables, with no Rustler precompiled or Mix asset downloads.
      preConfigure = ''
        # A fixed-output fetch can be reused from cache after inputs change.
        # Reject a stale hash rather than compiling old deps against a new lock.
        cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"
      '' + lib.optionalString isMarshall ''
        export CARGO_HOME="$TMPDIR/cargo-home"
        mkdir -p "$CARGO_HOME"
        substitute ${cedarCargo}/.cargo/config.toml "$CARGO_HOME/config.toml" \
          --subst-var-by vendor "${cedarCargo}"
        cat >> config/prod.exs <<'CONFIG'
        config :esbuild, path: "${lib.getExe pkgs.esbuild}", version: "${pkgs.esbuild.version}"
        CONFIG
      '';

      postBuild = lib.optionalString isMarshall ''
        # fetchMixDeps removes Git internals; the hash and lock snapshot above
        # authenticate inputs. Mark dependency loading complete before the
        # asset alias invokes compile again without the builder's flags.
        mix do deps.loadpaths --no-deps-check + assets.deploy
      '';

      # @cc [owner:ghuntley,label:deployment] source-release-runtime-metadata
      # Metadata MUST retain the canonical runtime tool paths used by Lilly;
      # exporting a release closure MUST include every referenced executable.
      postInstall = ''
        cp ${metadata} "$out/overalls-release.json"
        ${lib.optionalString isLilly ''ln -s ${hostTools} "$out/host-tools"''}
      '';
      meta = {
        description = "Overalls ${application} source-built OTP release";
        mainProgram = application;
        platforms = [ "x86_64-linux" ];
      };
    };
in
rec {
  inherit dependencies cedarCargo hostTools toolchain vmm windowsFirmware windowsFirmwareDebug mkWindowsGuest windowsGuest windowsGuestAgents windowsGuestDrvload windowsBoot;
  inherit terminald terminaldChecks terminaldWindows;
  inherit codingClis;
  inherit lyra lyraLinux lyraWindows lyraNative;
  marvin = import ./marvin { inherit pkgs; };
  vscodeWeb = import ./vscode-web { inherit pkgs; };
  updateVscodeExtensions = import ./vscode-web/updater.nix { inherit pkgs vscodeWeb; };
  vscodeWebBroker = import ./vscode-web-broker { inherit pkgs; };
  smtprelay = pkgs.callPackage ./smtprelay {};
  underclass = pkgs.callPackage ./underclass {};
  secretTools = { inherit (pkgs) secretspec sops ssh-to-age age; };
  userRecipients = secretPackages.recipients;
  secrets = secretPackages.command;
  marshall = release "marshall";
  lilly = release "lilly";
  audi = release "audi";
  brady = release "brady";
  porsche = release "porsche";
  ziggy = release "ziggy";
  galileo = release "galileo";
  enrico = release "enrico";
  guest = import ./guest {
    inherit pkgs privateServiceRoots terminald lyraLinux vscodeWeb vscodeWebBroker codingClis;
    minimumMemoryBytes = 2147483648;
  };
  mkUbuntuGuest = import ./guest/ubuntu { inherit pkgs terminald lyraLinux vscodeWeb vscodeWebBroker codingClis; };
  ubuntuGuest = mkUbuntuGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  # Foreign Linux variants share the reviewed kernel/initrd boot contract while
  # their builders assemble roots from separately pinned distribution inputs.
  # The builders install the generic Linux guest runtime and keep image
  # identities separate in the fleet catalog by distribution and source pin.
  mkArchGuest = import ./guest/arch { inherit pkgs mkUbuntuGuest terminald lyraLinux; };
  archGuest = mkArchGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  mkArchLinuxGuest = mkArchGuest;
  archLinuxGuest = archGuest;
  mkAlmaLinuxGuest = import ./guest/alma { inherit pkgs mkUbuntuGuest terminald lyraLinux; };
  almaLinuxGuest = mkAlmaLinuxGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  # Short aliases follow the catalog's display name and preserve discoverability
  # for callers that use the conventional Alma naming.
  mkAlmaGuest = mkAlmaLinuxGuest;
  almaGuest = almaLinuxGuest;
  # Native non-Linux guests use the v6 manifest and never reuse the Linux
  # rootfs assembly. The CloudHv firmware is the same pinned PVH artifact used
  # by the firmware launcher, so OmniOS receives the identical PCI contract.
  nativeGuestAgents = nativeAgentPayload;
  nativeKernels = nativeGuests.nativeKernels;
  nativeGuests = import ./guest/native.nix { inherit pkgs lyra; firmware = windowsFirmware.fd; };
  nativeImagePromotion = import ./guest/native-promotion { inherit pkgs; elixir = toolchain.elixir; };
  mkPromotedNativeGuest = nativeImagePromotion.promote;
  mkPublishedNativeCandidate = nativeImagePromotion.publishedCandidate;
  nativeImagePromotionChecks = nativeImagePromotion.checks;
  mkFreeBSDGuest = import ./guest/freebsd { inherit pkgs; firmware = windowsFirmware.fd; nativeAgents = lyraNative; };
  freebsdGuest = import ./guest/native-promotion/freebsd.nix { inherit pkgs; elixir = toolchain.elixir; };
  # Candidate assembly is an explicit build target. The staging constructor
  # stays closed; the catalog consumes only the separately promoted identity.
  mkFreeBSDImageCandidate = extraArgs: import ./guest/freebsd/candidate.nix ({
    inherit pkgs;
    kernel = nativeKernels.freebsdCandidate;
    agentNames = nativeAgentPayload.manifest.agents;
    stagedImage = mkFreeBSDGuest {
      imageName = "overalls-freebsd-native-staging";
      kernel = nativeKernels.freebsdCandidate;
      stagingOnly = true;
    };
  } // extraArgs);
  freebsdImageCandidate = mkFreeBSDImageCandidate { };
  omniosImageCandidateKit = import ./guest/omnios/candidate.nix {
    inherit pkgs;
    kernel = nativeKernels.illumosCandidate;
    agents = nativeAgentPayload.illumos;
    git = (import ./guest/native-git.nix { inherit pkgs; }).illumos;
    source = nativeGuests.mkOmniOSSource;
  };
  freebsdTransportProbeImage = mkFreeBSDImageCandidate {
    extraRoot = pkgs.runCommand "overalls-freebsd-transport-probe-root" {} ''
      install -D -m 0555 \
        ${lyra.native.probes}/bin/x86_64-unknown-freebsd-overalls-native-transport-probe \
        "$out/usr/local/libexec/overalls-native-transport-probe"
    '';
    runtimeRcLocal = pkgs.writeText "overalls-freebsd-transport-probe-rc.local" ''
      #!/bin/sh
      exec /usr/local/libexec/overalls-native-transport-probe
    '';
  };
  # OmniOS has no offline ZFS mutation hook in the Linux builder. Keep its
  # pinned bootable image independent of the FreeBSD daemon payload until an
  # illumos libc SDK and SMF installation path are both available.
  mkOmniOSGuest = import ./guest/omnios { inherit pkgs; firmware = windowsFirmware.fd; };
  omniosGuest = mkOmniOSGuest { };
  # illumos.org is the upstream project; its installable downstream image is
  # exposed through an explicit constructor so callers do not mistake the
  # OmniOS distribution name for a second image source.
  mkIllumosGuest = import ./guest/illumos { inherit pkgs; firmware = windowsFirmware.fd; };
  illumosGuest = mkIllumosGuest { };
  ubuntuLock = import ./guest/ubuntu/lock-tool.nix { inherit pkgs; };
  imageBuilder = import ./guest/inception/image-builder.nix { inherit pkgs terminald lyraLinux; };
  inceptionGuest = import ./guest {
    inherit pkgs;
    inherit privateServiceRoots terminald lyraLinux codingClis;
    imageName = "inception-nixos-x86_64";
    minimumMemoryBytes = 34359738368;
    extraModules = [ (import ./guest/inception {
      packages = { inherit marshall lilly audi porsche ziggy guest smtprelay toolchain secretTools imageBuilder lyra; };
    }) ];
  };
  inceptionProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis;
    privateServiceRoots = [ ];
    imageName = "inception-nesting-probe-x86_64";
    minimumMemoryBytes = 2147483648;
    extraModules = [
      ./guest/nesting-probe/minimal.nix
      (import ./guest/nesting-probe { image = nestingProbeGuest; })
    ];
  };
} // lib.optionalAttrs (!encryptedCrashDumps) {
  encrypted = import ./. { inherit pkgs privateServiceRoots; encryptedCrashDumps = true; };
}
