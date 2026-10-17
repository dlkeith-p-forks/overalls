{ pkgsPath, releaseDirectory, application }:
let
  pkgs = import (builtins.toPath pkgsPath) {};
  toolchain = import ./toolchain.nix { inherit pkgs; };
  hostLock = import ./host-tools.nix { inherit pkgs; };
  hostTools = pkgs.buildEnv {
    name = "lilly-host-tools";
    paths = [ pkgs.coreutils pkgs.diffutils pkgs.util-linux pkgs.iproute2 pkgs.nftables
      pkgs.procps pkgs.openssh toolchain.elixir toolchain.erlang hostLock ];
  };
  release = builtins.path { path = builtins.toPath releaseDirectory; name = "${application}-release-input"; };
  # @cc [owner:ghuntley,label:deployment] bundle-metadata-runtime-references
  # metadata MUST describe the actual toolchain and, for Lilly, retain store
  # references to the executable paths used by its generated host configuration.
  metadata = pkgs.writeText "${application}-release.json" (builtins.toJSON ({
    format = 1;
    inherit application;
    platform = pkgs.stdenv.hostPlatform.system;
    elixir = toolchain.elixir.version;
    otp = toolchain.erlang.version;
  } // pkgs.lib.optionalAttrs (application == "lilly") {
    host_tools = "${hostTools}";
    firecracker = "${pkgs.pkgsStatic.firecracker}/bin/firecracker";
    jailer = "${pkgs.pkgsStatic.firecracker}/bin/jailer";
    unshare = "${pkgs.util-linux.bin}/bin/unshare";
  }));
in
# @cc [owner:ghuntley,label:build] release-input-validation
# The bundle expression MUST reject applications other than Marshall/Lilly/Audi/Porsche and
# input directories without that application's release executable before copying.
assert builtins.elem application [ "marshall" "lilly" "audi" "porsche" ];
assert builtins.pathExists "${release}/bin/${application}";
pkgs.runCommand "overalls-${application}-release" {} ''
  mkdir -p "$out"
  cp -a ${release}/. "$out/"
  chmod -R u+w "$out"
  cp ${metadata} "$out/overalls-release.json"
  ${pkgs.lib.optionalString (application == "lilly") ''ln -s ${hostTools} "$out/host-tools"''}
  # Nix registers references in copied ELF files, scripts and metadata. The
  # exported closure supplies their pinned runtime libraries on the target host.
''
