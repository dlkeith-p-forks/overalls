{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.hypothesis ps.pyyaml ]);
in
# @cc [owner:ghuntley,label:verification] updater-custody-executable-check
# This check MUST execute the generated custody and recovery histories against
# the supplied production updater runtime, the production prepare.py publication
# helper and the real SecretSpec/SOPS/age toolchain inside a disposable uid-0
# user namespace with confined /run/overalls-auto-update, /var/lib/overalls-auto-update
# and /run/current-system paths. It runs standalone formatting and typing of all
# copied sources. It MUST NOT claim systemd, database migration, guest survival
# or native deployment acceptance.
pkgs.runCommand "overalls-auto-update-custody" {
  nativeBuildInputs = [
    python pkgs.ruff pkgs.ty pkgs.sops pkgs.age pkgs.ssh-to-age pkgs.secretspec
    pkgs.openssh pkgs.bubblewrap pkgs.util-linux
  ];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  export RUFF_CACHE_DIR="$TMPDIR/ruff"
  export XDG_CACHE_HOME="$TMPDIR/cache"
  mkdir checks
  cd checks
  cp ${../../../domains/system/auto-update/runtime.py} updater_runtime.py
  cp ${../../../domains/system/secrets/prepare.py} secrets_prepare.py
  cp ${../../../domains/artifacts/secrets/cli.py} secrets_cli.py
  cp ${../machines/auto-update/custody_histories.py} custody_histories.py
  # Keep the repository lint config below this directory so standalone typing
  # cannot inherit its source include filter. Explicitly check all copied files.
  mkdir config
  cp ${../../../../pyproject.toml} config/pyproject.toml
  ruff format --check --config config/pyproject.toml .
  ruff check --config config/pyproject.toml .
  ty check --python ${python}/bin/python3 --python-version 3.13 \
    updater_runtime.py secrets_prepare.py custody_histories.py
  sops --version
  start=$SECONDS
  fixture="$TMPDIR/custody"
  mkdir -p "$fixture/rt" "$fixture/st" "$fixture/work"
  chmod 700 "$fixture/rt" "$fixture/st"
  ETC_BINDS=""
  for file in group passwd nsswitch.conf; do
    if [ -e "/etc/$file" ]; then ETC_BINDS="$ETC_BINDS --ro-bind /etc/$file /etc/$file"; fi
  done
  bwrap \
    --ro-bind /nix/store /nix/store \
    $ETC_BINDS \
    --bind "$fixture/work" /work \
    --bind "$PWD" /checks \
    --tmpfs /run \
    --bind "$fixture/rt" /run/overalls-auto-update \
    --bind "$fixture/st" /var/lib/overalls-auto-update \
    --dev /dev --bind /dev/shm /dev/shm --proc /proc \
    --unshare-user --unshare-pid --uid 0 --gid 0 \
    --chdir /work \
    --setenv CUSTODY_WORK /work \
    --setenv PATH "$PATH" \
    -- ${python}/bin/python3 /checks/custody_histories.py \
       /checks/secrets_prepare.py /checks/secrets_cli.py -v
  echo "histories duration: $((SECONDS - start)) seconds"
  mkdir -p "$out"
  echo passed > "$out/result"
''
