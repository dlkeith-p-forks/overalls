{ pkgs }:
let
  support = ../support;
  entries = builtins.readDir support;
  files = builtins.filter
    (name: entries.${name} == "regular" && pkgs.lib.hasPrefix "native_" name && pkgs.lib.hasSuffix ".py" name)
    (builtins.attrNames entries);
in
# @cc [owner:ghuntley,label:verification] native-fixture-boundary-regressions
# The host-side native fixture boundary tests MUST execute with pinned Git,
# OpenSSH and FAT tools. Their parser, refusal and cleanup evidence MUST NOT
# establish a native boot, kernel transport or catalog admission.
pkgs.runCommand "overalls-native-fixture-tests" {
  nativeBuildInputs = [ pkgs.python313 pkgs.git pkgs.openssh pkgs.openssl pkgs.mtools pkgs.util-linux ];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  mkdir support
  ${pkgs.lib.concatMapStringsSep "\n" (name: "cp ${support + "/${name}"} support/${name}") files}
  python3.13 -m unittest discover -s support -p 'native_*_test.py'
  touch "$out"
''
