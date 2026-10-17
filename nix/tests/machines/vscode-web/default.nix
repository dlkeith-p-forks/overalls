{ pkgs, packages }:
let
  inherit (pkgs) lib;
  editor = packages.vscodeWeb;
  broker = packages.vscodeWebBroker;
  browserExtension = import ./web-extension.nix { inherit pkgs editor; };
  nativeExtension = import ./native-extension.nix { inherit pkgs editor; };
  lowerPersonalExtension = import ./personal-extension.nix { inherit pkgs editor; version = "0.18.1"; };
  newerPersonalExtension = import ./personal-extension.nix { inherit pkgs editor; version = "0.18.3"; };
  coreBuiltinExtension = import ./personal-extension.nix { inherit pkgs editor; identity = "core"; version = "100.0.0"; };
  elixirServer = import ./offline-elixir-ls.nix { inherit pkgs; inherit (packages) toolchain; };
  # @cc [owner:ghuntley,label:verification] editor-project-elixir-fixture-custody
  # The positive Elixir project MUST select compiled offline server scripts with
  # a project override. Its pinned runtime/server closure MUST NOT enter the
  # guest's global compiler profile or use the extension's bundled installer.
  elixirFixtureAdapters = pkgs.symlinkJoin {
    name = "editor-fixture-elixir-server-adapters";
    paths = [
      (pkgs.writeShellScriptBin "language_server.sh" ''
        export PATH=${lib.makeBinPath [ packages.toolchain.elixir elixirServer pkgs.coreutils ]}:"$PATH"
        export HEX_OFFLINE=1
        exec ${elixirServer}/bin/elixir-ls "$@"
      '')
      (pkgs.writeShellScriptBin "elixir_check.sh" ''
        exec ${packages.toolchain.elixir}/bin/elixir "$@"
      '')
    ];
  };
  id = "11111111-1111-4111-8111-111111111111";
  label = "e-ceirceircfardairceirceirce-ceirceircfardairceirceirce";
  hostname = "${label}.apps.example.test";
  origin = "https://${hostname}";
  bobId = "22222222-2222-4222-8222-222222222222";
  bobLabel = "e-ceirceircfardairceirceirce-eirceircejbcfarceirceircei";
  bobHostname = "${bobLabel}.apps.example.test";
  bobOrigin = "https://${bobHostname}";
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  pki = pkgs.runCommand "vscode-web-fixture-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=overalls-editor-test-root -keyout root.key -out "$out/root.pem" 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=apps.example.test -keyout "$out/server.key" -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:*.apps.example.test,DNS:open-vsx.org\nextendedKeyUsage=serverAuth\n' > ext.cnf
    openssl x509 -req -in server.csr -CA "$out/root.pem" -CAkey root.key -CAcreateserial \
      -days 3650 -extfile ext.cnf -out "$out/server.pem" 2>/dev/null
  '';
  fixturePreface = {
    version = 1;
    binding = {
      vm_id = id; host_id = id; placement_id = id; session_id = id;
      execution_epoch = 7; generation = 1;
      inherit label;
      service = "editor"; port = 4444;
      user_id = id; guest_account_id = id; uid = 200001; username = "alice";
      editor_protocol = editor.editorProtocol;
      editor_commit = editor.sourceCommit;
      editor_release = editor.releaseId;
      editor_origin = origin;
    };
  };
  binding = pkgs.writeText "vscode-web-fixture-preface.json" (builtins.toJSON fixturePreface);
  bobBinding = pkgs.writeText "vscode-web-fixture-bob-preface.json" (builtins.toJSON (fixturePreface // {
    binding = fixturePreface.binding // {
      user_id = bobId; guest_account_id = bobId; uid = 200002; username = "bob";
      label = bobLabel; editor_origin = bobOrigin;
    };
  }));
  changedBinding = pkgs.writeText "vscode-web-fixture-new-origin.json" (builtins.toJSON (fixturePreface // {
    binding = fixturePreface.binding // {
      editor_origin = "https://${label}.editor.example.test:8443";
    };
  }));
  authorizer = pkgs.writeShellScript "editor-fixture-current-roster" ''
    test "$#" = 2 && test "$1" = ensure && { test "$2" = alice || test "$2" = bob; }
  '';
  conflictingSettings = pkgs.writeText "editor-fixture-conflicting-settings.json" (builtins.toJSON {
    "security.workspace.trust.enabled" = true;
    "security.workspace.trust.startupPrompt" = "always";
    "security.workspace.trust.emptyWindow" = false;
    "chat.disableAIFeatures" = false;
    "workbench.disableAICustomizations" = false;
  });
  # @cc [owner:ghuntley,label:verification] editor-project-rust-fixture-custody
  # The offline project MUST use the native server and scoped Cargo/rustc with
  # compiled standard libraries. Source-library discovery MUST stay disabled;
  # registry access and a global guest compiler profile MUST NOT supply evidence.
  rustSettings = pkgs.writeText "editor-fixture-offline-rust-settings.json" (builtins.toJSON {
    "rust-analyzer.server.path" = "${pkgs.rust-analyzer}/bin/rust-analyzer";
    "rust-analyzer.server.extraEnv".PATH = lib.makeBinPath [ pkgs.cargo pkgs.rustc pkgs.coreutils ];
    "rust-analyzer.server.extraEnv".CARGO_NET_OFFLINE = "true";
    "rust-analyzer.cargo.extraArgs" = [ "--offline" ];
    "rust-analyzer.cargo.metadataExtraArgs" = [ "--offline" ];
    "rust-analyzer.cargo.sysroot" = null;
    "rust-analyzer.checkOnSave" = true;
    "rust-analyzer.diagnostics.useRustcErrorCode" = true;
  });
  elixirSettings = pkgs.writeText "editor-fixture-offline-elixir-settings.json" (builtins.toJSON {
    "elixirLS.languageServerOverridePath" = "${elixirFixtureAdapters}/bin";
    "elixirLS.dialyzerEnabled" = false;
    "elixirLS.fetchDeps" = false;
    "elixirLS.mixEnv" = "test";
  });
  configuration = pkgs.writeText "vscode-web-fixture-broker.json" (builtins.toJSON {
    descriptor = { protocol = editor.editorProtocol; commit = editor.sourceCommit; release = editor.releaseId; };
    editor_executable = "${editor}/bin/overalls-code";
    systemd_run = "${pkgs.systemd}/bin/systemd-run";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    account_authorizer = "${authorizer}";
    worker_path = "/run/current-system/sw/bin";
  });
  helpers = pkgs.runCommand "vscode-web-fixture-typed" { nativeBuildInputs = [ pkgs.ty pkgs.ruff ]; } ''
    mkdir -p "$out" config
    cp ${./bridge.py} "$out/bridge.py"
    cp ${./browser.py} "$out/browser.py"
    cp ${../../../modules/otel-guest/browser_journey.py} "$out/browser_journey.py"
    cp ${./prepare.py} "$out/prepare.py"
    cp ${./policy.py} "$out/policy.py"
    cp ${./foreign_peer.py} "$out/foreign_peer.py"
    cp ${../../../../pyproject.toml} config/pyproject.toml
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --python ${python}/bin/python3 "$out"
  '';
in
(pkgs.testers.runNixOSTest {
  name = "overalls-vscode-web-native";
  defaults = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.interfaces.eth0.vlan = 1;
    virtualisation.vlans = lib.mkForce [ ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.networkingOptions = lib.mkForce [ ];
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    networking.firewall.enable = false;
    security.pki.certificates = [ (builtins.readFile "${pki}/root.pem") ];
  };
  nodes.guest = { ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 1;
    virtualisation.diskSize = 8192;
    boot.kernelParams = [ "lilly.ipv4=10.10.0.2" "lilly.placement=${id}" "lilly.execution_epoch=7" ];
    networking.interfaces.eth0.ipv4.addresses = [{ address = "10.10.0.2"; prefixLength = 32; }];
    networking.interfaces.eth0.ipv4.routes = [{ address = "10.10.0.1"; prefixLength = 32; }];
    networking.defaultGateway = { address = "10.10.0.1"; interface = "eth0"; };
    networking.nameservers = [ "10.10.0.1" ];
    users.groups.alice.gid = 200001;
    users.users.alice = { isNormalUser = true; uid = 200001; group = "alice"; home = "/home/alice"; homeMode = "0700"; };
    users.groups.bob.gid = 200002;
    users.users.bob = { isNormalUser = true; uid = 200002; group = "bob"; home = "/home/bob"; homeMode = "0700"; };
    environment.systemPackages = [ editor broker python pkgs.git pkgs.ripgrep pkgs.curl pkgs.jq pkgs.direnv ];
    systemd.services.editor-fixture-workspace = {
      wantedBy = [ "multi-user.target" ];
      before = [ "overalls-vscode-web.service" ];
      path = [ pkgs.git pkgs.coreutils pkgs.util-linux ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        # @cc [owner:ghuntley,label:verification] editor-fresh-personal-policy-fixtures
        # Both accounts MUST start without trust storage or installed compilers.
        # Conflicting personal trust/AI settings, outside-HOME folders and local
        # native fixtures MUST retain their independent personal ownership.
        for account in alice bob; do
          task_personal_home=/home/$account
          data=$task_personal_home/.local/share/overalls/vscode-web
          mkdir -p "$data/data/Machine"
          install -m 600 ${conflictingSettings} "$data/data/Machine/settings.json"
          for workspace in "$task_personal_home/workspace" "/opt/overalls-editor-$account"; do
            mkdir -p "$workspace"
            printf 'root = true\n\n[*]\nindent_style = space\nindent_size = 3\n' > "$workspace/.editorconfig"
            printf 'EditorConfig fixture\n' > "$workspace/indent.txt"
            printf 'printf "approved\\n" > "$PWD/direnv-executed.marker"\nexport OVERALLS_FIXTURE_DIRENV=approved\n' > "$workspace/.envrc"
            chown -R "$account:$account" "$workspace"
          done
          chown -R "$account:$account" "$task_personal_home/.local"
          runuser -u "$account" -- ${editor}/bin/overalls-code --install-extension ${nativeExtension}/native-fixture.vsix \
            --server-data-dir "$data" --disable-telemetry
        done
        mkdir -p /home/alice/workspace
        printf '{"answer":42,"nested":{"value":true}}\n' > /home/alice/workspace/format.json
        printf '{"broken": }\n' > /home/alice/workspace/invalid.json
        printf '# Browser package fixture\n\nfixture-search-needle\n\n![local-resource](local.svg)\n' > /home/alice/workspace/README.md
        printf '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="blue"/></svg>\n' > /home/alice/workspace/local.svg
        cd /home/alice/workspace
        git init -q
        git -c safe.directory=/home/alice/workspace -c user.name=fixture -c user.email=fixture@example.test add .
        git -c safe.directory=/home/alice/workspace -c user.name=fixture -c user.email=fixture@example.test commit -qm fixture
        chown -R alice:alice /home/alice/workspace
        mkdir -p /opt/overalls-editor-rust/src /opt/overalls-editor-rust/.vscode
        printf '[package]\nname = "native_fixture"\nversion = "0.1.0"\nedition = "2024"\n' > /opt/overalls-editor-rust/Cargo.toml
        printf 'fn main() { let _: u32 = "fixture"; }\n' > /opt/overalls-editor-rust/src/main.rs
        cp ${rustSettings} /opt/overalls-editor-rust/.vscode/settings.json
        chown -R bob:bob /opt/overalls-editor-rust
        mkdir -p /opt/overalls-editor-elixir/lib /opt/overalls-editor-elixir/.vscode
        printf 'defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: "0.1.0", deps: []]\nend\n' > /opt/overalls-editor-elixir/mix.exs
        printf 'defmodule Fixture do\n  def answer, do: (\nend\n' > /opt/overalls-editor-elixir/lib/fixture.ex
        cp ${elixirSettings} /opt/overalls-editor-elixir/.vscode/settings.json
        chown -R bob:bob /opt/overalls-editor-elixir
        runuser -u alice -- ${editor}/bin/overalls-code --install-extension ${browserExtension}/browser-fixture.vsix \
          --server-data-dir /home/alice/.local/share/overalls/vscode-web --disable-telemetry
      '';
    };
    systemd.services.overalls-vscode-web = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "editor-fixture-workspace.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "editor-fixture-workspace.service" ];
      serviceConfig = {
        ExecStart = "${broker}/bin/overalls-vscode-web-broker ${configuration}";
        RuntimeDirectory = "overalls-vscode";
        RuntimeDirectoryMode = "0711";
        RuntimeDirectoryPreserve = "yes";
        UMask = "0077";
      };
    };
  };
  nodes.gateway = { ... }: {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    networking.interfaces.eth0.ipv4.addresses = [
      { address = "10.10.0.1"; prefixLength = 24; }
      { address = "10.10.0.3"; prefixLength = 24; }
    ];
    networking.nameservers = [ "127.0.0.1" ];
    services.dnsmasq = {
      enable = true;
      settings = { address = [ "/apps.example.test/10.10.0.1" "/open-vsx.org/10.10.0.1" ]; no-resolv = true; };
    };
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools pkgs.curl ];
    systemd.services.editor-fixture-bridge = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig.ExecStart = "${python}/bin/python ${helpers}/bridge.py ${binding}";
    };
    systemd.services.editor-fixture-bob-bridge = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig.ExecStart = "${python}/bin/python ${helpers}/bridge.py ${bobBinding} --port 8081";
    };
    services.nginx = {
      enable = true;
      serverNamesHashBucketSize = 128;
      mapHashBucketSize = 128;
      recommendedProxySettings = true;
      # @cc [owner:ghuntley,label:verification] editor-local-gallery-exact-origins
      # The inert local gallery MUST support both fixture accounts' exact origins
      # while refusing any other origin; it MUST NOT contact a public gallery.
      commonHttpConfig = ''
        map $http_origin $fixture_gallery_origin {
          default "";
          "${origin}" "${origin}";
          "${bobOrigin}" "${bobOrigin}";
        }
      '';
      virtualHosts.${hostname} = {
        forceSSL = true;
        sslCertificate = "${pki}/server.pem";
        sslCertificateKey = "${pki}/server.key";
        locations."/" = { proxyPass = "http://127.0.0.1:8080"; proxyWebsockets = true; };
      };
      virtualHosts.${bobHostname} = {
        forceSSL = true;
        sslCertificate = "${pki}/server.pem";
        sslCertificateKey = "${pki}/server.key";
        locations."/" = { proxyPass = "http://127.0.0.1:8081"; proxyWebsockets = true; };
      };
      virtualHosts."~^[a-z0-9-]+\\.apps\\.example\\.test$" = {
        onlySSL = true;
        sslCertificate = "${pki}/server.pem";
        sslCertificateKey = "${pki}/server.key";
        locations."/code-assets/${editor.releaseId}/" = {
          alias = "${editor}/";
        };
      };
      virtualHosts."open-vsx.org" = {
        onlySSL = true;
        sslCertificate = "${pki}/server.pem";
        sslCertificateKey = "${pki}/server.key";
        locations."/".extraConfig = ''
          default_type application/json;
          add_header Access-Control-Allow-Origin $fixture_gallery_origin always;
          add_header Vary "Origin" always;
          add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
          add_header Access-Control-Allow-Headers "Content-Type, X-Market-Client-Id, X-Market-Search-Activity-Id" always;
          return 200 '{"results":[{"extensions":[],"resultMetadata":[]}]}';
        '';
      };
    };
  };
  # @cc [owner:ghuntley,label:verification] editor-kernel-custody-and-worker-recovery
  # Native requests MUST prove the actual source commit and Linux worker UID,
  # refuse foreign account/release/epoch/gateway inputs and wrong kernel peer UID,
  # preserve worker PID and saved data across an unchanged broker restart, and
  # recover after worker loss. A changed admitted origin MUST create a fresh
  # worker advertising that authority while retaining saved user data.
  testScript = ''
    import json

    start_all()
    guest.wait_for_unit("editor-fixture-workspace.service")
    guest.wait_for_unit("overalls-vscode-web.service")
    gateway.wait_for_unit("nginx.service")
    gateway.wait_for_unit("editor-fixture-bridge.service")
    gateway.wait_for_unit("editor-fixture-bob-bridge.service")
    gateway.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    gateway.succeed("certutil -A -d sql:/root/.pki/nssdb -n editor-fixture -t C,, -i ${pki}/root.pem")
    gateway.wait_until_succeeds("ping -c1 -W1 10.10.0.2")
    guest.wait_until_succeeds("ping -c1 -W1 10.10.0.1")
    with subtest("closed guest admission refuses foreign authority before worker startup"):
        for reason in ("epoch", "placement", "release", "account", "name", "gateway"):
            gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --refuse " + reason)
        guest.fail("systemctl is-active --quiet overalls-vscode-u200001.service")
    with subtest("socket ownership cannot substitute for the kernel worker UID"):
        guest.succeed("install -d -m 700 -o alice -g alice /run/overalls-vscode/u200001")
        guest.succeed("systemd-run --unit=overalls-vscode-u200001 --collect ${python}/bin/python ${helpers}/foreign_peer.py")
        guest.wait_until_succeeds("test -S /run/overalls-vscode/u200001/editor.sock")
        guest.succeed("test $(stat -c %u:%a /run/overalls-vscode/u200001/editor.sock) = 200001:600")
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --refuse custody", timeout=45)
        guest.fail("test -e /run/editor-fixture-foreign-peer-received")
        guest.succeed("systemctl stop overalls-vscode-u200001.service")
    with subtest("real editor workbench, built-in tools and shared terminal custody"):
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --probe", timeout=45)
        guest.succeed("test $(stat -c %a /run/overalls-vscode/u200001/editor.sock) = 600")
        status, output = gateway.execute("${python}/bin/python ${helpers}/browser.py ${origin}", timeout=240)
        for artifact in ("/tmp/vscode-web-native.png", "/tmp/vscode-web-native-diagnostics.json"):
            gateway.succeed("test $(stat -c %a " + artifact + ") = 600")
        gateway.copy_from_machine("/tmp/vscode-web-native.png")
        if status != 0:
            gateway.copy_from_machine("/tmp/vscode-web-native-diagnostics.json")
            guest.succeed("test $(du -s --block-size=1 /home/alice/.local/share/overalls/vscode-web/data/logs | cut -f1) -le 8388608")
            guest.succeed("cp -a /home/alice/.local/share/overalls/vscode-web/data/logs /tmp/vscode-web-native-logs")
            guest.succeed("chmod -R go-rwx /tmp/vscode-web-native-logs")
            guest.copy_from_machine("/tmp/vscode-web-native-logs")
        assert status == 0, output
        assert "Browser terminal custody regression passed" in output
        guest.succeed("grep -Fxq 'Browser-only extension activated' /home/alice/workspace/web-extension.marker")
        guest.succeed("test $(stat -c %u /home/alice/workspace/web-extension.marker) = 200001")
        installed_extensions = guest.succeed("${pkgs.util-linux}/bin/runuser -u alice -- ${editor}/bin/overalls-code --list-extensions --server-data-dir /home/alice/.local/share/overalls/vscode-web --disable-telemetry")
        assert "overalls.overalls-browser-fixture" not in installed_extensions.splitlines()
        guest.wait_until_succeeds("test $(cat /home/alice/.editor-terminal-uid) = 200001")
        formatted = guest.succeed("cat /home/alice/workspace/format.json")
        formatted_value: object = json.loads(formatted)
        assert formatted_value == {"answer": 42, "nested": {"value": True}}
        assert len(formatted.splitlines()) >= 3
    # @cc [owner:ghuntley,label:verification] editor-native-personal-policy-acceptance
    # HOME and outside-HOME workspaces MUST report workspace.isTrusted through
    # the native API under conflicting personal settings. Both accounts MUST
    # receive immutable defaults, while disable state and user overrides stay
    # independent. Direnv MUST refuse before approval and apply the actual
    # project environment after approval. Rust evidence MUST run the real server
    # from an offline project fixture, never a fake LSP or global compiler.
    def editor_policy(origin: str, folder: str, mode: str) -> None:
        gateway.succeed("${python}/bin/python ${helpers}/policy.py " + origin + " " + folder + " " + mode, timeout=180)

    with subtest("all folders are trusted and both personal accounts receive immutable defaults"):
        editor_policy("${origin}", "/opt/overalls-editor-alice", "defaults")
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${bobBinding} --probe-workbench", timeout=45)
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
        editor_policy("${bobOrigin}", "/opt/overalls-editor-bob", "defaults")
        for account in ("alice", "bob"):
            for folder in ("/home/" + account + "/workspace", "/opt/overalls-editor-" + account):
                guest.succeed("test $(stat -c %u " + folder + "/native-policy.marker) = " + ("200001" if account == "alice" else "200002"))
                guest.fail("test -e " + folder + "/direnv-executed.marker")
        guest.fail("command -v rustc")
        guest.fail("command -v cargo")
        guest.fail("command -v elixir")
    with subtest("direnv keeps unapproved environments inert and applies approved project values"):
        editor_policy("${origin}", "/home/alice/workspace", "direnv")
        guest.succeed("test $(stat -c %u /home/alice/workspace/direnv-executed.marker) = 200001")
        guest.succeed("grep -Fxq approved /home/alice/workspace/direnv-executed.marker")
        guest.fail("test -e /home/bob/workspace/direnv-executed.marker")
    with subtest("personal newer versions override immutable defaults and uninstall restores the system version"):
        # The native installer enforces the immutable system version floor.
        # Refusing this import does not establish historical on-disk scanning.
        lower_status, lower_refusal = guest.execute("${pkgs.util-linux}/bin/runuser -u bob -- ${editor}/bin/overalls-code --install-extension ${lowerPersonalExtension}/personal-version.vsix --force --server-data-dir /home/bob/.local/share/overalls/vscode-web --disable-telemetry 2>&1")
        assert lower_status != 0
        assert "cannot be downgraded to version" in lower_refusal
        guest.fail("test -d /home/bob/.local/share/overalls/vscode-web/extensions/editorconfig.editorconfig-0.18.1")
        guest.succeed("systemctl stop overalls-vscode-u200002.service")
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
        guest.succeed("${pkgs.util-linux}/bin/runuser -u bob -- ${editor}/bin/overalls-code --install-extension ${newerPersonalExtension}/personal-version.vsix --force --server-data-dir /home/bob/.local/share/overalls/vscode-web --disable-telemetry")
        guest.succeed("systemctl stop overalls-vscode-u200002.service")
        editor_policy("${bobOrigin}", "/home/bob/workspace", "version")
        editor_policy("${origin}", "/home/alice/workspace", "defaults")
        guest.succeed("${pkgs.util-linux}/bin/runuser -u bob -- ${editor}/bin/overalls-code --uninstall-extension EditorConfig.EditorConfig --force --server-data-dir /home/bob/.local/share/overalls/vscode-web --disable-telemetry")
        guest.succeed("systemctl stop overalls-vscode-u200002.service")
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
    # @cc [owner:ghuntley,label:verification;security] editor-native-core-builtin-refusal
    # The reviewed third-party manual update roster MUST NOT admit a newer core
    # builtin payload or permit removing the immutable system default.
    with subtest("core builtin updates and system bundle removal remain refused"):
        core_status, core_refusal = guest.execute("${pkgs.util-linux}/bin/runuser -u bob -- ${editor}/bin/overalls-code --install-extension ${coreBuiltinExtension}/personal-version.vsix --force --server-data-dir /home/bob/.local/share/overalls/vscode-web --disable-telemetry 2>&1")
        assert core_status != 0
        assert "is a built-in extension and not allowed to be updated" in core_refusal
        guest.fail("test -d /home/bob/.local/share/overalls/vscode-web/extensions/vscode.git-100.0.0")
        system_refusal = guest.succeed("${pkgs.util-linux}/bin/runuser -u bob -- ${editor}/bin/overalls-code --uninstall-extension EditorConfig.EditorConfig --force --server-data-dir /home/bob/.local/share/overalls/vscode-web --disable-telemetry 2>&1")
        assert "is a Built-in extension and cannot be uninstalled" in system_refusal
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
    with subtest("immutable defaults retain independent personal disable and override controls"):
        editor_policy("${origin}", "/home/alice/workspace", "disable")
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
        editor_policy("${origin}", "/home/alice/workspace", "disabled")
        editor_policy("${origin}", "/home/alice/workspace", "overrides")
        editor_policy("${bobOrigin}", "/home/bob/workspace", "defaults")
    with subtest("the universal Rust extension uses the actual offline project language server"):
        editor_policy("${bobOrigin}", "/opt/overalls-editor-rust", "rust")
        guest.succeed("test $(stat -c %u /opt/overalls-editor-rust/native-rust.marker) = 200002")
    with subtest("ElixirLS uses the actual compiled offline project language server override"):
        editor_policy("${bobOrigin}", "/opt/overalls-editor-elixir", "elixir")
        guest.succeed("test $(stat -c %u /opt/overalls-editor-elixir/native-elixir.marker) = 200002")
        guest.fail("test -e /home/bob/.cache/elixir_ls")
    with subtest("broker restart preserves independent worker and saved data"):
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --probe", timeout=45)
        pid = guest.succeed("systemctl show -p MainPID --value overalls-vscode-u200001.service").strip()
        assert int(pid) > 0
        guest.succeed("systemctl restart overalls-vscode-web.service")
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --probe")
        assert guest.succeed("systemctl show -p MainPID --value overalls-vscode-u200001.service").strip() == pid
        guest.succeed("test $(cat /home/alice/.editor-terminal-uid) = 200001")
    with subtest("changed admitted origin recreates the worker and preserves saved data"):
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${changedBinding} --probe-workbench", timeout=45)
        changed_pid = guest.succeed("systemctl show -p MainPID --value overalls-vscode-u200001.service").strip()
        assert int(changed_pid) > 0 and changed_pid != pid
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --probe-workbench", timeout=45)
        restored_pid = guest.succeed("systemctl show -p MainPID --value overalls-vscode-u200001.service").strip()
        assert int(restored_pid) > 0 and restored_pid != changed_pid
        saved: object = json.loads(guest.succeed("cat /home/alice/workspace/format.json"))
        assert saved == {"answer": 42, "nested": {"value": True}}
        guest.succeed("test $(cat /home/alice/.editor-terminal-uid) = 200001")
        pid = restored_pid
    with subtest("worker loss starts a fresh personal process without deleting data"):
        guest.succeed("systemctl stop overalls-vscode-u200001.service")
        gateway.succeed("${python}/bin/python ${helpers}/bridge.py ${binding} --probe", timeout=45)
        new_pid = guest.succeed("systemctl show -p MainPID --value overalls-vscode-u200001.service").strip()
        assert int(new_pid) > 0 and new_pid != pid
        guest.succeed("test $(cat /home/alice/.editor-terminal-uid) = 200001")
  '';
}) // { inherit helpers; }
