{ pkgs, packages, expectedConnectionCheckMs ? 1000, expectedTcpUserTimeoutMs ? 15000, activeHolder ? false, faultMode ? "crash" }:
assert builtins.elem faultMode [ "crash" "silent" "asymmetric" ];
let
  root = "/var/lib/overalls-fleet";
  client = pkgs.writeShellScriptBin "database-recovery-client" ''
    set -euo pipefail
    set -a
    . ${root}/marshall.env
    set +a
    export PHX_SERVER=false PHX_HOST=control.example.test RELEASE_DISTRIBUTION=none
    export RELEASE_COOKIE=isolated-database-recovery RELEASE_TMP=/run/database-recovery
    export MARSHALL_INSTANCE_ID=recovery-client MARSHALL_REPLICA_COUNT=1
    export MARSHALL_DB_CONNECTION_BUDGET=21 POOL_SIZE=10 MARSHALL_DB_TLS=verify
    export MARSHALL_DB_CA_CERTFILE=${root}/ca.crt ERL_CRASH_DUMP=/dev/null ERL_FLAGS="+S 2:2"
    export FLEET_RECOVERY_ACTIVE=${if activeHolder then "true" else "false"}
    ${pkgs.coreutils}/bin/mkdir -p "$RELEASE_TMP"
    exec ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./client.exs}")'
  '';
in
# @cc [owner:ghuntley,label:verification] database-recovery-real-release
# This fixture MUST use the production release Repo and PostgreSQL across two
# machines. Three observed lock waiters MUST exist before client loss;
# neither server timeout overrides nor explicit backend termination may pass it.
pkgs.testers.runNixOSTest {
  name = "overalls-database-recovery${if activeHolder then "-active" else ""}${if faultMode == "crash" then "" else "-${faultMode}"}";
  globalTimeout = 300;
  nodes = {
    db = { ... }: {
      virtualisation.memorySize = 1024;
      environment.systemPackages = [ pkgs.nftables ];
      imports = [ (import ../../support/fleet-database.nix {
        generationService = "recovery-credentials";
        maxConnections = 32;
        allowedNetwork = "192.168.1.0/24";
      }) ];
    };
    m1 = { ... }: {
      virtualisation.memorySize = 1024;
      environment.systemPackages = [ client ];
    };
  };
  testScript = ''
    expected_connection_check_ms = ${toString expectedConnectionCheckMs}
    expected_tcp_user_timeout_ms = ${toString expectedTcpUserTimeoutMs}
    expected_holder_state = "${if activeHolder then "active" else "idle in transaction"}"
    fault_mode = "${faultMode}"
  '' + builtins.readFile ./driver.py;
}
