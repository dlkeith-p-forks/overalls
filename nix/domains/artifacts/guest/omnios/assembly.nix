{ pkgs, kit, source, firmware, memoryMiB ? 2048, timeoutSeconds ? 2400 }:
assert kit.os == "illumos" && !kit.nativeAdmission;
assert kit.kernel ? buildId;
assert memoryMiB >= 2048 && memoryMiB <= 8192;
assert timeoutSeconds >= 600 && timeoutSeconds <= 7200;
let
  inherit (pkgs) lib;
  buildId = kit.kernel.buildId;
  python = pkgs.python313;
  # A disposable stock administration copy cannot import its identical twin,
  # so its own root pool is re-GUIDed in a separate first offline boot.
  reguidCommands = pkgs.writeText "overalls-omnios-reguid-commands" ''
    zpool reguid rpool
    zpool list -H -o name,guid
    /usr/sbin/poweroff
  '';
  assembleCommands = pkgs.writeText "overalls-omnios-assemble-commands" ''
    devfsadm; mkdir -p /mnt/kit; found=; for d in /dev/dsk/c*p1; do mount -F pcfs -o ro $d /mnt/kit 2>/dev/null || continue; if test -f /mnt/kit/overalls-kit; then found=$d; break; fi; umount /mnt/kit; done; test -n "$found"
    /bin/sh /mnt/kit/overalls-assemble.sh
    umount /mnt/kit
    /usr/sbin/poweroff
  '';
  tools = pkgs.runCommand "overalls-omnios-assembly-tools" {
    nativeBuildInputs = [ python pkgs.ruff pkgs.ty ];
  } ''
    mkdir -p "$out" config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    cp ${./serial_session.py} "$out/serial_session.py"
    cp ${./check_assembly.py} "$out/check_assembly.py"
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${python}/bin/python3.13 --python-version 3.13 "$out"
  '';
in
# @cc [owner:ghuntley,label:build;verification;isolation] omnios-nix-native-assembly
# Assembly MUST run only offline bounded KVM guests from the pinned stock image:
# a disposable re-GUIDed administration copy links the exact Nix-built objects
# with the guest's Solaris ld and installs them into a scratch copy that is
# verified against the pinned whole-disk digest before mutation. Its receipts
# MUST bind actual module, unix, assembly-receipt and final raw-disk hashes,
# check unchanged-object modules against the promoted receipt and record that
# the raw ZFS disk is not bit-reproducible. It MUST NOT grant admission or
# claim booted, transport, service, isolation or recovery acceptance.
pkgs.runCommand "overalls-omnios-native-image-candidate" {
  nativeBuildInputs = [
    python pkgs.qemu_kvm pkgs.zstd pkgs.mtools pkgs.dosfstools pkgs.util-linux
    pkgs.gnutar pkgs.jq pkgs.coreutils
  ];
  requiredSystemFeatures = [ "kvm" ];
  preferLocalBuild = true;
  passthru = {
    inherit kit firmware buildId tools;
    kernel = kit.kernel;
    os = "illumos";
    nativeAdmission = false;
    imageAssemblyReady = false;
    runtimeValidated = false;
    reproducibleRawDisk = false;
  };
} ''
  set -euo pipefail
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$out/evidence"
  ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
  zstd -dc ${source} | dd of="$TMPDIR/admin.raw" bs=1M conv=sparse status=none
  base_bytes=$(jq -er .base_bytes ${kit}/kit.json)
  base_sha256=$(jq -er .base_sha256 ${kit}/kit.json)
  test "$(stat -c %s "$TMPDIR/admin.raw")" -eq "$base_bytes"
  test "$(sha256sum "$TMPDIR/admin.raw" | cut -d ' ' -f1)" = "$base_sha256"
  cp --sparse=always "$TMPDIR/admin.raw" "$out/disk.raw"
  chmod u+w "$out/disk.raw"

  python3.13 ${tools}/serial_session.py --qemu ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
    --log "$out/evidence/reguid-serial.log" --commands ${reguidCommands} \
    --timeout 900 --memory ${toString memoryMiB} --drive "rw:$TMPDIR/admin.raw"

  # The transfer disk is read-only to the guest and carries exact kit modes.
  make_fat() {
    local directory=$1 image=$2 label=$3 serial=$4 bytes mib
    bytes=$(du -sb --apparent-size "$directory" | cut -f1)
    mib=$(( bytes / 1048576 + 96 ))
    truncate -s "$(( mib + 1 ))M" "$image"
    printf 'label: dos\nlabel-id: 0x5a17cafe\nstart=2048, type=c, bootable\n' | sfdisk --quiet "$image"
    truncate -s "''${mib}M" "$TMPDIR/partition.img"
    mkfs.fat -F 32 -n "$label" -i "$serial" "$TMPDIR/partition.img" > /dev/null
    find "$directory" -exec touch -h -d @315532800 {} +
    mcopy -s -m -i "$TMPDIR/partition.img" "$directory"/* ::
    dd if="$TMPDIR/partition.img" of="$image" bs=1M seek=1 conv=notrunc,sparse status=none
    rm "$TMPDIR/partition.img"
  }
  mkdir "$TMPDIR/transfer" "$TMPDIR/evidence-root"
  tar --format=gnu --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C ${kit} -cf "$TMPDIR/transfer/kit.tar" .
  install -m 0444 ${./guest-assemble.sh} "$TMPDIR/transfer/overalls-assemble.sh"
  printf '%s\n' '${buildId}' > "$TMPDIR/transfer/build-id"
  : > "$TMPDIR/transfer/overalls-kit"
  : > "$TMPDIR/evidence-root/overalls-evidence"
  make_fat "$TMPDIR/transfer" "$TMPDIR/kit.img" OVERALLSKIT 12CEA600
  make_fat "$TMPDIR/evidence-root" "$TMPDIR/evidence.img" OVERALLSEVD 12CEA601

  if ! python3.13 ${tools}/serial_session.py --qemu ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
    --log "$out/evidence/assembly-serial.log" --commands ${assembleCommands} \
    --timeout ${toString timeoutSeconds} --memory ${toString memoryMiB} \
    --drive "rw:$TMPDIR/admin.raw" --drive "rw:$out/disk.raw" \
    --drive "ro:$TMPDIR/kit.img" --drive "rw:$TMPDIR/evidence.img"; then
    tr -d '\r' < "$out/evidence/reguid-serial.log" | tail -n 40 >&2
    tr -d '\r' < "$out/evidence/assembly-serial.log" | tail -n 120 >&2
    mcopy -i "$TMPDIR/evidence.img@@1M" ::assembly.log - >&2 || :
    exit 1
  fi
  mkdir "$TMPDIR/extracted"
  mcopy -s -n -i "$TMPDIR/evidence.img@@1M" '::*' "$TMPDIR/extracted/"
  for name in assembly.log zpool-imported.txt slice-labels.txt pool-guid installed-modules.txt \
    assembly-receipt.json linked-receipt.json install-receipt.json kernel-build-id \
    sock2path-overalls-native-vsock guest-status; do
    install -m 0444 "$TMPDIR/extracted/$name" "$out/evidence/$name"
  done
  test "$(cat "$out/evidence/sock2path-overalls-native-vsock")" = '40 2 0 sockvsock'
  python3.13 ${tools}/check_assembly.py --evidence "$TMPDIR/extracted" --kit ${kit} \
    --disk "$out/disk.raw" --reference ${./promoted-assembly-reference.json} \
    --build-id '${buildId}' --output "$TMPDIR/checked"
  install -m 0444 "$TMPDIR/checked/manifest.json" "$out/manifest.json"
  install -m 0444 "$TMPDIR/checked/candidate-receipt.json" "$out/evidence/candidate-receipt.json"
  chmod a-w "$out/disk.raw"
''
