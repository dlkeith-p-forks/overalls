{
  description = "Marshall control plane and Lilly Firecracker hosts";

  # @cc [owner:ghuntley,label:build] flake-package-inputs
  # Application packages MUST use the same locked package input as devenv;
  # NixOS host modules MUST use the separately locked stable NixOS input.
  inputs = {
    nix-compact.url = "github:ghuntley/nix-compact/7b4205856cd01b2c356197689daabcca19baa7af";
    buildNixpkgs.url = "github:cachix/devenv-nixpkgs/256551e45f6303e142ab4a98be1bf243feb77dc0";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-images = {
      url = "github:nix-community/nixos-images/4fcaaefd02b5bc777f99afd620cb1a9aa1fb5b83";
      inputs.nixos-stable.follows = "nixpkgs";
      inputs.nixos-unstable.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/ff8702b4de27f72b4c78573dfb89ec74e36abdf1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, buildNixpkgs, nixpkgs, disko, nixos-images, nix-compact }:
    let
      system = "x86_64-linux";
      pkgs = buildNixpkgs.legacyPackages.${system};
      built = import ./nix/packages { inherit pkgs; };
      antithesisImages = import ./antithesis/nix { inherit pkgs nixpkgs; };
      hostPackages = import ./nix/packages {
        inherit pkgs;
        privateServiceRoots = [ ./secrets/private-services-root.pem ./secrets/brady-root.pem ];
      };
      inventory = import ./nix/hosts/inventory.nix { inherit (nixpkgs) lib; };
      fixtures = import ./nix/tests/fixtures/hosts/configurations.nix { inherit nixpkgs disko; modules = self.nixosModules; };
      hostSystem = name: enrolled: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { overallsPackages = hostPackages; };
        modules = [ self.nixosModules.default (import ./nix/hosts/profile.nix {
          host = inventory.hosts.${name}; diskoModule = disko.nixosModules.disko; inherit enrolled;
        }) ] ++ nixpkgs.lib.optionals (enrolled && builtins.pathExists (./fleet/hosts + "/${name}/configuration.nix"))
          [ (./fleet/hosts + "/${name}/configuration.nix") ];
      };
    in
    {
      # @cc [owner:ghuntley,label:build] flake-releases-from-source
      # Exported application packages MUST compile clean source and locked
      # dependencies; existing working-tree releases MUST NOT be build inputs.
      lib.mkUbuntuGuest = built.mkUbuntuGuest;
      lib.mkArchGuest = built.mkArchGuest;
      lib.mkArchLinuxGuest = built.mkArchLinuxGuest;
      lib.mkAlmaLinuxGuest = built.mkAlmaLinuxGuest;
      lib.mkAlmaGuest = built.mkAlmaGuest;
      lib.mkFreeBSDGuest = built.mkFreeBSDGuest;
      lib.mkOmniOSGuest = built.mkOmniOSGuest;
      lib.mkIllumosGuest = built.mkIllumosGuest;
      lib.nativeKernels = built.nativeKernels;
      packages.${system} = {
        nix-compact = nix-compact.lib.mkPackage { inherit pkgs; };
        nix-compact-host = nix-compact.lib.mkPackage { pkgs = nixpkgs.legacyPackages.${system}; };
        inherit (built) marshall lilly audi porsche ziggy galileo enrico brady guest hostTools smtprelay underclass lyra browser;
        ubuntu-guest = built.ubuntuGuest;
        freebsd-guest = built.freebsdGuest;
        omnios-guest = built.omniosGuest;
        illumos-guest = built.illumosGuest;
        freebsd-kernel-receipt = built.nativeKernels.freebsdKernel;
        illumos-kernel-receipt = built.nativeKernels.illumosKernel;
        illumos-sdk-receipt = built.nativeKernels.illumosSdk;
        arch-guest = built.archGuest;
        archlinux-guest = built.archLinuxGuest;
        alma-linux-guest = built.almaLinuxGuest;
        almalinux-guest = built.almaLinuxGuest;
        vscode-web = built.vscodeWeb;
        update-vscode-extensions = built.updateVscodeExtensions;
        ubuntu-lock = built.ubuntuLock;
        inception-guest = built.inceptionGuest;
        # Windows guest spike (ADR-0169): patched VMM, PVH UEFI firmware,
        # evaluation-ISO image and the standalone serial-console launcher.
        firecracker = built.vmm;
        windows-firmware = built.windowsFirmware;
        windows-guest = built.windowsGuest;
        windows-boot = built.windowsBoot;
        marshall-encrypted-dumps = built.encrypted.marshall;
        lilly-encrypted-dumps = built.encrypted.lilly;
        audi-encrypted-dumps = built.encrypted.audi;
        brady-encrypted-dumps = built.encrypted.brady;
        porsche-encrypted-dumps = built.encrypted.porsche;
        user-recipients = built.userRecipients;
        secrets = built.secrets;
        host = import ./nix/packages/host { pkgs = nixpkgs.legacyPackages.${system}; };
        host-kexec = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ nixos-images.nixosModules.kexec-installer nixos-images.nixosModules.noninteractive
            ({ config, pkgs, ... }: {
              system.kexec-installer.name = "overalls-host-installer";
              environment.systemPackages = [ pkgs.python3 config.boot.zfs.package ];
              boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
            }) ];
        }).config.system.build.kexecInstallerTarball;
        default = built.marshall;
      } // (pkgs.lib.mapAttrs' (name: context:
        pkgs.lib.nameValuePair "antithesis-${name}-context" context
      ) antithesisImages.contexts);

      legacyPackages.${system} = built;

      nixosModules = {
        nix-compact = import ./nix/modules/nix-compact.nix { nixCompact = nix-compact; };
        backups = { imports = [ (import ./nix/modules/backups { packages = built; }) self.nixosModules.lilly self.nixosModules.marshall self.nixosModules.secrets ]; };
        logging = ./nix/modules/logging/default.nix;
        cloudwatch = ./nix/modules/cloudwatch/default.nix;
        security-audit = ./nix/modules/security-audit.nix;
        access = ./nix/modules/access.nix;
        fleet-firewall = ./nix/modules/fleet-firewall.nix;
        tailscale = ./nix/modules/tailscale.nix;
        underclass = import ./nix/modules/underclass.nix { packages = built; };
        remote-builders = { imports = [ ./nix/modules/remote-builders.nix self.nixosModules.secrets ]; };
        sysctl = ./nix/modules/sysctl.nix;
        default = import ./nix/modules { packages = built; nixCompact = nix-compact; };
        marshall = import ./nix/modules/marshall.nix { packages = built; };
        lilly = import ./nix/modules/lilly.nix { packages = built; };
        brady = import ./nix/modules/brady { packages = built; };
        porsche = import ./nix/modules/porsche.nix { packages = built; };
        audi-private = import ./nix/modules/audi-private.nix { packages = built; };
        ziggy = import ./nix/modules/ziggy.nix { packages = built; };
        galileo = import ./nix/modules/galileo.nix { packages = built; };
        enrico = import ./nix/modules/enrico.nix { packages = built; };
        audi = import ./nix/modules/audi.nix { packages = built; };
        proxy = { imports = [ self.nixosModules.marshall ./nix/modules/proxy.nix ]; };
        acme = { imports = [ self.nixosModules.proxy ./nix/modules/acme/default.nix ]; };
        secrets = import ./nix/modules/secrets/default.nix { packages = built; };
        auto-update = import ./nix/modules/auto-update/default.nix { packages = built; };

      };

      nixosConfigurations = nixpkgs.lib.mapAttrs (name: _: hostSystem name true)
        (nixpkgs.lib.filterAttrs (name: host: host.identity.sshKeys != []
          && host.git.knownHosts != "" && nixpkgs.lib.any (document: document.name == "${name}-git") host.credentials) inventory.hosts)
        // nixpkgs.lib.mapAttrs' (name: _: nixpkgs.lib.nameValuePair "${name}-base" (hostSystem name false)) inventory.hosts;

      checks.${system} = (import ./nix/tests {
        buildPkgs = pkgs;
        testPkgs = nixpkgs.legacyPackages.${system};
        inherit nixpkgs;
        packages = built;
        modules = self.nixosModules;
        inherit fixtures;
        diskoModule = disko.nixosModules.disko;
        diskoSource = disko.outPath;
        kexec = self.packages.${system}.host-kexec;
        imageSource = nixos-images.outPath;
      }) // {
        nix-compact-core = nix-compact.lib.mkCoreCheck { inherit pkgs; };
        nix-compact-native = nix-compact.lib.mkNativeCheck { inherit pkgs; };
        nix-compact-native-host = nix-compact.lib.mkNativeCheck { pkgs = nixpkgs.legacyPackages.${system}; };
        nix-compact-configuration = import ./nix/packages/nix-compact/configuration-check.nix { inherit nixpkgs; nixCompact = nix-compact; };
        hldd = pkgs.runCommand "overalls-hldd-check" {
          nativeBuildInputs = [ built.toolchain.elixir ];
          LC_ALL = "C.UTF-8";
          source = ./.;
          optionDeclarations = pkgs.writeText "overalls-hldd-options.json"
            (builtins.toJSON (import ./scripts/hldd/options.nix { flake = self; }));
          deploymentTopology = pkgs.writeText "overalls-hldd-topology.json"
            (builtins.toJSON (import ./scripts/hldd/topology.nix { flake = self; }));
        } ''
          cd "$source"
          elixir scripts/check_hldd.exs
          elixir scripts/hldd_options.exs --check "$optionDeclarations"
          elixir scripts/hldd_views.exs --check "$deploymentTopology"
          touch "$out"
        '';
        conflict-markers = pkgs.runCommand "overalls-conflict-markers-check" {
          nativeBuildInputs = [ built.toolchain.elixir pkgs.git ];
          LC_ALL = "C.UTF-8";
          source = ./.;
        } ''
          export HOME="$TMPDIR"
          cd "$source"
          find . -type f -not -path './.git/*' -print0 > "$TMPDIR/files"
          xargs -0 elixir scripts/check_conflict_markers.exs < "$TMPDIR/files"
          touch "$out"
        '';
        terminald = built.terminaldChecks;
        terminald-windows = built.terminaldWindows;
        overalls-install-ps1 = import ./nix/tests/overalls-install-ps1.nix { inherit pkgs; };
        lyra = built.lyra.tests;
        browser = built.browser.tests;
      };
    };
}
