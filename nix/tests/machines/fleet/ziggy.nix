{ pkgs, root, agent ? false, executorLoss ? false, codingClis ? false }:
let
  provider = pkgs.runCommand "fleet-provider-catalog-typed" { nativeBuildInputs = [ pkgs.ty ]; } ''
    mkdir -p "$out"
    cp ${./provider-catalog.py} "$out/provider-catalog.py"
    ty check --python ${pkgs.python3}/bin/python3 "$out/provider-catalog.py"
  '';
  tls = pkgs.runCommand "fleet-isolated-provider-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=fleet-isolated-provider -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=api.openai.com -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:api.openai.com,DNS:api.anthropic.com\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in {
  inherit tls;
  # @cc [owner:ghuntley,label:verification;security] fleet-ziggy-provider-isolation
  # The fleet MUST keep mandatory Ziggy and Galileo enabled with real Marshall credentials.
  # Provider discovery and explicitly selected coding-client/agent responses
  # MUST use isolated TLS fixtures and synthetic provider keys. This fixture
  # MUST NOT provide synthetic control authority or claim live-provider acceptance.
  lilly = { nodes, ... }: {
    networking.extraHosts = "${nodes.m1.networking.primaryIPAddress} api.openai.com api.anthropic.com";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    # @cc [owner:ghuntley,label:verification;capacity] fleet-coding-clis-host-provider-budget
    # Only the selected coding-client fixture may raise Ziggy's test override
    # to 1024 MiB after the recorded 512 MiB startup cgroup OOM. This host-side
    # fixture allowance MUST NOT change guest resource or headroom assertions,
    # other fleet variants, or the production Ziggy memory default.
    services.ziggy = { secretsFile = "${root}/ziggy.enc.json"; cpuCores = 1; memoryMiB = if codingClis then 1024 else 512; agentEnable = agent; };
    services.galileo = { secretsFile = "${root}/galileo.enc.json"; cpuCores = 1; memoryMiB = 512; };
    systemd.services.fleet-ziggy-credentials = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 600; };
      script = ''
        while [ ! -f ${root}/ziggy.enc.json ] || [ ! -f ${root}/galileo.enc.json ]; do sleep 1; done
      '';
    };
    systemd.services.overalls-secrets-ziggy = {
      after = [ "fleet-ziggy-credentials.service" ];
      requires = [ "fleet-ziggy-credentials.service" ];
    };
    systemd.services.overalls-secrets-galileo = {
      after = [ "fleet-ziggy-credentials.service" ];
      requires = [ "fleet-ziggy-credentials.service" ];
    };
  };
  provider = {
    networking.firewall.allowedTCPPorts = [ 443 ];
    systemd.services.fleet-provider-catalog = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${provider}/provider-catalog.py ${tls}/server.pem ${tls}/server.key ${if codingClis then "coding-clis" else if executorLoss then "executor-loss" else if agent then "agent" else "discovery"}";
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
