{ pkgs, packages }:
let
  arch = packages.mkArchGuest { imageName = "arch-evaluation"; };
  alma = packages.mkAlmaLinuxGuest { imageName = "alma-evaluation"; };
  plain = builtins.unsafeDiscardStringContext;
  archCommand = plain arch.buildCommand;
  almaCommand = plain alma.buildCommand;
  # @cc [owner:ghuntley,label:verification] foreign-linux-builder-evaluation
  # Arch and Alma builders MUST use their own pinned upstream rootfs inputs;
  # a marker alone is not evidence of a different distribution.
  check = image: command: marker:
    assert image.passthru.distribution == marker;
    assert image.passthru.sourceFormat != "ubuntu";
    assert pkgs.lib.hasInfix "version:4" command;
    assert pkgs.lib.hasInfix "kernel:{bytes:" command;
    assert pkgs.lib.hasInfix "rootfs:{bytes:" command;
    assert pkgs.lib.hasInfix "overalls.distribution=" command;
    assert builtins.elem image.passthru.sourceFormat [ "arch-bootstrap" "qcow2-ext4" ];
    true;
in
assert check arch archCommand "arch";
assert check alma almaCommand "almalinux";
assert arch.name == "arch-evaluation";
assert alma.name == "alma-evaluation";
pkgs.runCommand "foreign-linux-guest-evaluation" { } ''
  test ${pkgs.lib.escapeShellArg arch.passthru.distribution} = arch
  test ${pkgs.lib.escapeShellArg alma.passthru.distribution} = almalinux
  touch "$out"
''
