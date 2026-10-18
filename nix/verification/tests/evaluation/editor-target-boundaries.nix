{ pkgs, packages }:
let
  # @cc [owner:ghuntley,label:verification;security] editor-target-boundary
  # The reviewed editor and broker are Linux-only artifacts. Native v6 and
  # Windows v5 package metadata MUST remain editor-free until a complete
  # target-native runtime, service boundary and browser acceptance exists.
  editorPlatforms = packages.vscodeWeb.meta.platforms or [ ];
  brokerPlatforms = packages.vscodeWebBroker.meta.platforms or [ ];
  nativeManifest = packages.nativeGuestAgents.manifest;
  nativeCapabilities = nativeManifest.capabilities or [ ];
  nativePackages = [ packages.freebsdGuest packages.illumosGuest ];
  windowsPackage = packages.windowsGuest;
  passthru = package: package.passthru or { };
in
assert editorPlatforms == [ "x86_64-linux" ];
assert brokerPlatforms == [ "x86_64-linux" ];
assert nativeManifest.native_admission == false;
assert !(builtins.elem "editor" nativeCapabilities);
assert builtins.all (package:
  !(package ? editor) && !(passthru package ? editor)
) nativePackages;
assert !(windowsPackage ? editor) && !(passthru windowsPackage ? editor);
pkgs.runCommand "overalls-editor-target-boundaries" { } ''
  cat > "$out" <<'EOF'
editor-platforms=x86_64-linux
broker-platforms=x86_64-linux
native-v6-editor=false
windows-v5-editor=false
EOF
''
