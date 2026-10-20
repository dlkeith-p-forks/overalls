{ config, lib, pkgs, overallsPackages, ... }:
let
  marshall = config.services.marshall;
  images = import ../../guest-images.nix { inherit overallsPackages; };
  stagedImages = import ../../staged-guest-images.nix { inherit overallsPackages; };
  catalog = pkgs.writeText "overalls-images.json" (builtins.toJSON (map (image: {
    inherit (image) name;
    manifest = "${image.package}/manifest.json";
  }) images));
  # @cc [owner:ghuntley,label:deployment] overalls-default-installed-image
  # The default MUST be derived by the shared manifest validator from the exact
  # image registered below and staged on Lilly, never from a second ID algorithm.
  # Standalone validation MUST compile EditorRelease, GuestAgents, ImageManifest
  # and NativeAdmission together so every manifest uses the complete shared
  # protocol schema.
  # NativeAdmission reads the reviewed native histories at compile time.
  protocolSource = lib.fileset.toSource {
    root = ../../../protocol;
    fileset = lib.fileset.unions [
      ../../../protocol/lib/overalls_protocol/editor_release.ex
      ../../../protocol/lib/overalls_protocol/guest_agents.ex
      ../../../protocol/lib/overalls_protocol/image_manifest.ex
      ../../../protocol/lib/overalls_protocol/native_admission.ex
      ../../../protocol/priv/native
    ];
  };
  protocol = "${protocolSource}/lib/overalls_protocol";
  imageIdentity = pkgs.runCommand "overalls-default-image-id" {
    nativeBuildInputs = [ overallsPackages.toolchain.elixir ];
  } ''
    export ERL_FLAGS="+S 2:2"
    mkdir "$TMPDIR/protocol-beams"
    elixirc -o "$TMPDIR/protocol-beams" \
      ${protocol}/editor_release.ex ${protocol}/guest_agents.ex \
      ${protocol}/image_manifest.ex ${protocol}/native_admission.ex
    elixir -pa "$TMPDIR/protocol-beams" -e '
      [source, output] = System.argv()
      {:ok, image} = source |> File.read!() |> JSON.decode!() |> OverallsProtocol.ImageManifest.validate()
      File.write!(output, image.id)
    ' ${overallsPackages.guest}/manifest.json "$out"
  '';
  mailEnvironment = import ../../../nix/domains/system/smtp-relay/environment.nix {
    inherit lib;
    cfg = marshall.smtpRelay;
  };
  registration = pkgs.writeText "overalls-register-image.exs" ''
    Application.put_env(:marshall, :operator_mode, true)
    with {:ok, _} <- Application.ensure_all_started(:marshall) do
      for entry <- "${catalog}" |> File.read!() |> JSON.decode!() do
        with {:ok, bytes} <- File.read(entry["manifest"]),
             {:ok, manifest} <- JSON.decode(bytes),
             {:ok, image} <- Marshall.Compute.Images.register(manifest, entry["name"]) do
          IO.puts("Registered guest image " <> image.id)
        else
          _ ->
            IO.puts(:stderr, "Guest image catalog registration failed")
            System.halt(1)
        end
      end
    else
      _ ->
        IO.puts(:stderr, "Guest image catalog registration failed")
        System.halt(1)
    end
  '';
in
{
  # @cc [owner:ghuntley,label:deployment] overalls-image-catalog-bootstrap
  # The exact guest manifest staged on Lilly MUST be registered through Marshall's
  # idempotent operator catalog before serving starts. Registration MUST preserve
  # existing catalog identity/state and use private runtime database credentials.
  services.lilly.images = map (image: { path = toString image.package; }) stagedImages;
  services.marshall.defaultImageId = builtins.readFile imageIdentity;
  services.marshall.secretUnits = [ "overalls-image-catalog.service" ];
  systemd.services.overalls-image-catalog = {
    description = "Register the installed guest image in Marshall";
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ catalog ];
    after = [ "overalls-database-password.service" "overalls-secrets-marshall.service" ];
    requires = [ "overalls-database-password.service" "overalls-secrets-marshall.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "marshall-operator";
      Group = "marshall-operator";
      UMask = "0077";
      EnvironmentFile = marshall.environmentFile;
      LoadCredential = [ "database-ca.crt:${marshall.databaseCAFile}" ];
      RuntimeDirectory = "overalls-image-catalog";
      RuntimeDirectoryMode = "0700";
      TimeoutStartSec = 120;
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
    script = ''
      export RELEASE_COOKIE
      RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
      exec ${pkgs.coreutils}/bin/env -u PORT ${mailEnvironment} \
        PHX_SERVER=false RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null \
        RELEASE_TMP=/run/overalls-image-catalog \
        PHX_HOST=${lib.escapeShellArg marshall.publicHost} \
        MARSHALL_INSTANCE_ID=image-catalog \
        MARSHALL_REPLICA_COUNT=${toString marshall.replicaCount} \
        POOL_SIZE=${toString marshall.poolSize} \
        MARSHALL_DB_CONNECTION_BUDGET=${toString marshall.databaseConnectionBudget} \
        MARSHALL_DB_TLS=verify MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
        ${marshall.package}/bin/marshall eval 'Code.eval_file("${registration}")'
    '';
  };
}
