{ pkgs, kernel, agents, git, source }:
let
  pythonSha256 = "fa8d4644c831a28b766237865b215cad766606a2b2727e250ce016cbee5ed404";
in
# @cc [owner:ghuntley,label:build;verification;isolation] omnios-native-candidate-kit
# The kit MUST carry exact native object, service, bootstrap and Git inputs,
# record the pinned stock image's whole-disk digest and native Python identity,
# and require target-native scratch-pool installation. A kit MUST NOT emit a
# production image manifest or establish module loadability/catalog admission.
pkgs.runCommand "overalls-omnios-native-image-candidate-kit" {
  nativeBuildInputs = [ pkgs.python313 pkgs.zstd ];
  passthru = {
    inherit kernel source;
    os = "illumos";
    nativeAdmission = false;
    imageAssemblyReady = false;
    runtimeValidated = false;
  };
} ''
  set -euo pipefail
  export PYTHONDONTWRITEBYTECODE=1
  mkdir "$TMPDIR/checks"
  cp ${../native-kernels/illumos/native_candidate.py} "$TMPDIR/checks/native_candidate.py"
  cp ${../native-kernels/illumos/native_image.py} "$TMPDIR/checks/native_image.py"
  cp ${../native-kernels/illumos/test_native_image.py} "$TMPDIR/checks/test_native_image.py"
  python3.13 "$TMPDIR/checks/test_native_image.py"
  mkdir -p "$out/root" "$out/kernel" "$out/bin"
  # The agents' /bin tree is a build interface, not a target FHS destination.
  cp -a ${agents}/etc ${agents}/lib ${agents}/opt "$out/root/"
  chmod -R u+w "$out/root"
  cp -a ${git}/. "$out/root/"
  chmod -R u+w "$out/root"
  mkdir -p "$out/root/etc/svc/profile/site"
  install -m 0444 ${./native-services.xml} "$out/root/etc/svc/profile/site/overalls-native-services.xml"
  cp -a ${kernel}/. "$out/kernel/"
  install -m 0555 ${../native-kernels/illumos/native_candidate.py} "$out/bin/native_candidate.py"
  install -m 0555 ${../native-kernels/illumos/native_image.py} "$out/bin/native_image.py"
  mkdir -p "$out/root/opt/overalls/libexec/image-candidate"
  cp "$out/bin/"*.py "$out/root/opt/overalls/libexec/image-candidate/"
  zstd -dc ${source} > "$TMPDIR/pinned.raw"
  python3.13 "$out/bin/native_image.py" pack "$out" '${kernel.buildId}' '${pythonSha256}' "$TMPDIR/pinned.raw"
''
