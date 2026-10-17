{ pkgs, packages }:
let
  arch = packages.mkArchGuest { imageName = "arch-evaluation"; };
  alma = packages.mkAlmaLinuxGuest { imageName = "alma-evaluation"; };
  plain = builtins.unsafeDiscardStringContext;
  archCommand = plain arch.buildCommand;
  almaCommand = plain alma.buildCommand;
  archRootCommand = plain arch.passthru.rootfs.buildCommand;
  almaRootCommand = plain alma.passthru.rootfs.buildCommand;
  archSourceName = builtins.baseNameOf (toString arch.passthru.source);
  almaSourceName = builtins.baseNameOf (toString alma.passthru.source);
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
# The source format remains part of the evaluated catalog contract, so a
# future refactor cannot silently present one distribution as the other.
assert arch.passthru.distribution != alma.passthru.distribution;
assert arch.passthru.sourceFormat != alma.passthru.sourceFormat;
assert pkgs.lib.hasInfix "archlinux-bootstrap" archSourceName;
assert pkgs.lib.hasInfix "AlmaLinux-10-GenericCloud" almaSourceName;
# The runtime setup is part of the rootfs derivation, rather than an
# evaluation-only marker. Keep these checks close to the image contract so a
# future source refactor cannot silently drop guest services.
assert pkgs.lib.hasInfix "overalls-trustd" archRootCommand;
assert pkgs.lib.hasInfix "overalls-workspaced" archRootCommand;
assert pkgs.lib.hasInfix "lilly-terminald" archRootCommand;
assert pkgs.lib.hasInfix "lilly-readiness.py" archRootCommand;
assert pkgs.lib.hasInfix "overalls-trustd" almaRootCommand;
assert pkgs.lib.hasInfix "overalls-workspaced" almaRootCommand;
assert pkgs.lib.hasInfix "lilly-terminald" almaRootCommand;
assert pkgs.lib.hasInfix "lilly-readiness.py" almaRootCommand;
pkgs.runCommand "foreign-linux-guest-evaluation" { } ''
  test ${pkgs.lib.escapeShellArg arch.passthru.distribution} = arch
  test ${pkgs.lib.escapeShellArg alma.passthru.distribution} = almalinux
  touch "$out"
''
