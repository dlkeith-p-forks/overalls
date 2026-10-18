{ pkgs, packages }:
let
  arch = packages.mkArchGuest { imageName = "arch-evaluation"; };
  alma = packages.mkAlmaLinuxGuest { imageName = "alma-evaluation"; };
  plain = builtins.unsafeDiscardStringContext;
  archCommand = plain arch.buildCommand;
  almaCommand = plain alma.buildCommand;
  archRootCommand = plain arch.passthru.rootfs.buildCommand;
  almaRootCommand = plain alma.passthru.rootfs.buildCommand;
  almaPrivate = packages.mkAlmaLinuxGuest {
    imageName = "alma-private-evaluation";
    privateServiceRoots = [ ../../../../secrets/private-services-root.pem ];
  };
  almaPrivateRootCommand = plain almaPrivate.passthru.rootfs.buildCommand;
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
    assert pkgs.lib.hasInfix "lsm=landlock,yama,bpf" command;
    assert builtins.elem image.passthru.sourceFormat [ "arch-bootstrap" "qcow2-ext4" ];
    true;
  # @cc [owner:ghuntley,label:verification] foreign-linux-determinism-inputs
  # Both foreign builders MUST fix filesystem clocks and hash seeds and avoid
  # directory st_size in image sizing. Evaluation guards these inputs only;
  # byte reproducibility requires rebuilding the actual rootfs derivations.
  reproducible = command:
    assert pkgs.lib.hasInfix "find ./rootImage \\( -type f -o -type l \\) -printf '%s\\n'" command;
    assert !(pkgs.lib.hasInfix "du -s -c -B 4096 --apparent-size ./rootImage" command);
    assert pkgs.lib.hasInfix "touch -h -d @1" command;
    assert !(pkgs.lib.hasInfix "cp -a --reflink=auto" command);
    assert pkgs.lib.hasInfix "cp -a --no-preserve=links --reflink=auto" command;
    assert pkgs.lib.hasInfix "cp -a --no-preserve=ownership,links" command;
    assert !(pkgs.lib.hasInfix "cp -a --no-preserve=mode,ownership,links" command);
    assert pkgs.lib.hasInfix "chmod -R u+rwX ./files" command;
    assert !(pkgs.lib.hasInfix "chmod -R a+rwX ./files" command);
    assert pkgs.lib.hasInfix "E2FSPROGS_FAKE_TIME=1 FAKETIME_DONT_FAKE_STAT=1" command;
    assert pkgs.lib.hasInfix "hash_seed=44444444-4444-4444-8888-888888888888,lazy_itable_init=0,lazy_journal_init=0" command;
    assert pkgs.lib.hasInfix ''faketime -f "1970-01-01 00:00:01" resize2fs -M $img'' command;
    assert pkgs.lib.hasInfix ''faketime -f "1970-01-01 00:00:01" resize2fs $img $new_size'' command;
    true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-account-runtime-inputs
  # Both rootfs builders MUST own SSH/PAM policy, install executable account
  # tools with a fixed unit PATH, and copy sudo with setuid mode. These checks
  # guard assembly inputs only; runtime SSH and elevation require native boots.
  accountRuntime = command:
    assert pkgs.lib.hasInfix "cat > ./files/etc/ssh/sshd_config <<'EOF'" command;
    assert pkgs.lib.hasInfix "UsePAM yes" command;
    assert pkgs.lib.hasInfix "PermitRootLogin no" command;
    assert pkgs.lib.hasInfix "AuthorizedKeysFile none" command;
    assert pkgs.lib.hasInfix "AuthorizedKeysCommandUser overalls-ssh" command;
    assert pkgs.lib.hasInfix (plain "session requisite ${pkgs.pam}/lib/security/pam_exec.so quiet quiet_log type=open_session /usr/local/bin/overalls-ssh-authorize login") command;
    assert pkgs.lib.hasInfix (plain "install -m 0755 ${pkgs.sudo}/bin/sudo ./files/usr/bin/sudo") command;
    assert pkgs.lib.hasInfix (plain "fakeroot ${pkgs.runtimeShell} -e -c 'chmod 4755 ./rootImage/usr/bin/sudo; exec mkfs.ext4 \"$@\"' --") command;
    assert !(pkgs.lib.hasInfix (plain "ln -sfn ${pkgs.sudo}/bin/sudo") command);
    assert pkgs.lib.hasInfix (plain "${pkgs.glibc.getent}/bin/getent") command;
    assert pkgs.lib.hasInfix (plain "${pkgs.shadow}/bin/$tool") command;
    assert pkgs.lib.hasInfix "Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" command;
    assert pkgs.lib.hasInfix "ln -sfn ssh.service ./files/etc/systemd/system/sshd.service" command;
    assert pkgs.lib.hasInfix "@includedir /etc/sudoers.d" command;
    assert pkgs.lib.hasInfix "foreign_linux_accounts.py" command;
    assert pkgs.lib.hasInfix ''for directory in ./files/tmp ./files/var/tmp'' command;
    assert pkgs.lib.hasInfix ''chmod 1777 "$directory"'' command;
    true;
  # @cc [owner:ghuntley,label:verification;security] foreign-linux-pam-helper-assembly
  # Both builders MUST install the fixed runtime helper installer and order the
  # owned SSH listener after its successful persistent oneshot. Missing helper
  # units, dependencies or installation MUST fail, including on older inputs.
  pamHelperAssembly = command: pkgs.lib.all (input: pkgs.lib.hasInfix input command) [
    "./files/usr/local/lib/lilly/install-pam-helper"
    "cat > ./files/etc/systemd/system/overalls-pam-helpers.service <<'EOF'"
    "Requires=overalls-pam-helpers.service"
    "After=overalls-ssh-sync.service overalls-pam-helpers.service"
    "ExecStart=/usr/local/lib/lilly/install-pam-helper"
    "RemainAfterExit=yes"
    "../overalls-pam-helpers.service ./files/etc/systemd/system/multi-user.target.wants/overalls-pam-helpers.service"
  ];
in
assert check arch archCommand "arch";
assert check alma almaCommand "almalinux";
assert reproducible archRootCommand;
assert reproducible almaRootCommand;
assert accountRuntime archRootCommand;
assert accountRuntime almaRootCommand;
assert pamHelperAssembly archRootCommand;
assert pamHelperAssembly almaRootCommand;
assert !pamHelperAssembly (builtins.replaceStrings [ "cat > ./files/etc/systemd/system/overalls-pam-helpers.service <<'EOF'" ] [ "" ] archRootCommand);
assert !pamHelperAssembly (builtins.replaceStrings [ "Requires=overalls-pam-helpers.service" ] [ "" ] almaRootCommand);
assert !pamHelperAssembly (builtins.replaceStrings [ "After=overalls-ssh-sync.service overalls-pam-helpers.service" ] [ "After=overalls-ssh-sync.service" ] archRootCommand);
assert pkgs.lib.hasInfix "z / 0755 root root -" archRootCommand;
assert !(pkgs.lib.hasInfix "z / 0755 root root -" almaRootCommand);
# @cc [owner:ghuntley,label:verification;build;security] almalinux-resolver-assembly-scope
# Only private Alma roots MUST install the pinned resolver bundle and scoped
# identity bootstrap. Plain Alma and Arch assembly MUST retain their own paths.
assert pkgs.lib.hasInfix "example/systemd/system/$unit" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "systemd-resolved-monitor.socket" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "example/sysusers.d/systemd-resolve.conf" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "share/dbus-1/system.d/org.freedesktop.resolve1.conf" almaPrivateRootCommand;
assert pkgs.lib.hasInfix "share/dbus-1/system-services/org.freedesktop.resolve1.service" almaPrivateRootCommand;
assert pkgs.lib.hasInfix (plain "ExecStart=${pkgs.systemd}/bin/systemd-sysusers /usr/lib/sysusers.d/systemd-resolve.conf") almaPrivateRootCommand;
assert pkgs.lib.hasInfix "Requires=overalls-resolved-identity.service" almaPrivateRootCommand;
assert !(pkgs.lib.hasInfix "overalls-resolved-identity.service" almaRootCommand);
assert !(pkgs.lib.hasInfix "overalls-resolved-identity.service" archRootCommand);
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
pkgs.runCommand "foreign-linux-guest-evaluation" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  test ${pkgs.lib.escapeShellArg arch.passthru.distribution} = arch
  test ${pkgs.lib.escapeShellArg alma.passthru.distribution} = almalinux
  cp ${../../../domains/artifacts/guest/foreign_linux_accounts.py} foreign_linux_accounts.py
  cp ${../../../domains/artifacts/guest/test_foreign_linux_accounts.py} test_foreign_linux_accounts.py
  python3 -m unittest test_foreign_linux_accounts
  touch "$out"
''
