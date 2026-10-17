{ pkgs, mkUbuntuGuest, distribution, defaultImageName, source, sourceFormat }:
{ imageName ? defaultImageName
, privateServiceRoots ? [ ]
, minimumMemoryBytes ? 2147483648
, minimumDiskBytes ? 8589934592
}:
let
  inherit (pkgs) lib;
  # Reuse only the reviewed Firecracker Linux kernel/initrd contract. The
  # distribution rootfs is assembled from its own pinned release input below.
  boot = mkUbuntuGuest {
    imageName = "${imageName}-boot-contract";
    inherit privateServiceRoots minimumMemoryBytes;
  };
  archRoot = pkgs.callPackage (pkgs.path + "/nixos/lib/make-ext4-fs.nix") {
    storePaths = [ ];
    volumeLabel = "overalls-${distribution}";
    populateImageCommands = ''
      mkdir -p ./files
      ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.zstd}/bin/zstd --delay-directory-restore --extract --file ${source} --directory ./files --strip-components=1
      chmod -R u+rwX ./files
      mkdir -p ./files/etc ./files/var/lib/overalls
      printf '%s\n' 'overalls image: ${distribution}' > ./files/etc/overalls-distribution
      if [ ! -e ./files/sbin/init ]; then
        ln -s ../bin/sh ./files/sbin/init
      fi
    '';
  };
  rootfsDir = if sourceFormat == "arch-bootstrap" then null else pkgs.runCommand "${imageName}-rootfs" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.qemu-utils pkgs.util-linux ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    ${pkgs.qemu-utils}/bin/qemu-img convert -O raw -S 4k ${source} "$out/disk.raw"
    root_start=$(${pkgs.util-linux}/bin/sfdisk --json "$out/disk.raw" | ${pkgs.jq}/bin/jq -r '.partitiontable.partitions[] | select(.name == "root") | .start')
    root_size=$(${pkgs.util-linux}/bin/sfdisk --json "$out/disk.raw" | ${pkgs.jq}/bin/jq -r '.partitiontable.partitions[] | select(.name == "root") | .size')
    test -n "$root_start" -a "$root_start" != null
    test -n "$root_size" -a "$root_size" != null
    ${pkgs.coreutils}/bin/dd if="$out/disk.raw" of="$out/rootfs.ext4" bs=512 skip="$root_start" count="$root_size" iflag=fullblock conv=sparse status=none
    ${pkgs.coreutils}/bin/rm "$out/disk.raw"
  '';
  rootfs = if sourceFormat == "arch-bootstrap" then archRoot else "${rootfsDir}/rootfs.ext4";
in
pkgs.runCommand imageName {
  nativeBuildInputs = [ pkgs.jq ];
  preferLocalBuild = true;
  passthru = { inherit distribution source sourceFormat boot; };
} ''
  set -euo pipefail
  mkdir -p "$out"
  ln -s ${boot.bootKernel}/vmlinux "$out/kernel"
  ln -s ${boot.initrd}/initrd "$out/initrd"
  ln -s ${rootfs} "$out/rootfs.ext4"
  kernel_bytes=$(stat -Lc %s "$out/kernel")
  initrd_bytes=$(stat -Lc %s "$out/initrd")
  rootfs_bytes=$(stat -Lc %s "$out/rootfs.ext4")
  minimum_disk_bytes=$(( rootfs_bytes > ${toString minimumDiskBytes} ? rootfs_bytes : ${toString minimumDiskBytes} ))
  jq -n \
    --arg distro ${lib.escapeShellArg distribution} \
    --argjson memory ${toString minimumMemoryBytes} --argjson disk "$minimum_disk_bytes" \
    --argjson kernel_bytes "$kernel_bytes" --arg kernel_sha256 "$(sha256sum "$out/kernel" | cut -d' ' -f1)" \
    --argjson initrd_bytes "$initrd_bytes" --arg initrd_sha256 "$(sha256sum "$out/initrd" | cut -d' ' -f1)" \
    --argjson rootfs_bytes "$rootfs_bytes" --arg rootfs_sha256 "$(sha256sum "$out/rootfs.ext4" | cut -d' ' -f1)" \
    '{version:4,architecture:"x86_64",boot_args:("console=ttyS0 root=/dev/vda rw overalls.distribution=" + $distro),minimum_disk_bytes:$disk,minimum_memory_bytes:$memory,workspace_source_version:null,kernel:{bytes:$kernel_bytes,sha256:$kernel_sha256},initrd:{bytes:$initrd_bytes,sha256:$initrd_sha256},rootfs:{bytes:$rootfs_bytes,sha256:$rootfs_sha256}}' \
    > "$out/manifest.json"
''
