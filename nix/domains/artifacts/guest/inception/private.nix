{ packages }:
{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  cfg = {
    package = packages.audi;
    credentialFile = "/var/lib/inception/audi.token";
    controlCAFile = "/run/inception-public/ca.crt";
    certificateFile = "/var/lib/audi-private-certificates/current/chain.pem";
    keyFile = "/var/lib/audi-private-certificates/current/key.pem";
    rootsFile = "/run/inception-public/private-root.pem";
    secretUnits = [ "inception-private-runtime.service" "inception-audi.service" "inception-private-pki.service" ];
    certificateUnits = [ "audi-private-certificate.service" ];
  };
  services = import ../../../system/audi-private-services.nix {
    inherit pkgs cfg;
    namespacePath = "/run/inception/private-netns";
    runtime = "/run/credentials/audi-private.service/runtime.json";
    renewal = "/run/credentials/audi-private-certificate.service/renewal.json";
  };
in {
  imports = [
    (import ../../../system/audi-private-issuer.nix { inherit packages; })
    services
  ];

  # @cc [owner:ghuntley,label:security] inception-independent-private-issuer
  # The inner issuer MUST receive only its own runtime intermediate. Parent keys
  # and the instance recovery root MUST NOT enter the online issuer credentials.
  # Root generation remains outside the image and separate from public readiness.
  services.audiPrivateIssuer = {
    enable = true;
    issuerKeyFile = "/var/lib/inception/private-pki/issuer.key";
    issuerCertificateFile = "/var/lib/inception/private-pki/issuer.pem";
    secretUnits = [ "inception-private-pki.service" ];
  };
  systemd.services.audi-private.serviceConfig.LoadCredential = [
    "runtime.json:/run/inception/audi-private.json"
  ];
  systemd.services.audi-private-certificate.serviceConfig.LoadCredential = [
    "renewal.json:/run/inception/audi-private-renewal.json"
  ];
  systemd.services.inception-private-runtime = {
    after = [ "inception-enrollment.service" ];
    requires = [ "inception-enrollment.service" ];
    serviceConfig = {
      Type = "oneshot"; RemainAfterExit = true; UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${./.}/private_runtime.py";
      TimeoutStartSec = 30;
      CapabilityBoundingSet = [];
      NoNewPrivileges = true; PrivateDevices = true; PrivateNetwork = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
      ReadWritePaths = [ "/run/inception" ];
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };
  systemd.services.inception-private-pki = {
    description = "Independent Inception private-service PKI";
    wantedBy = [ "multi-user.target" ];
    after = [ "inception-identity.service" ];
    requires = [ "inception-identity.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      ExecStart = "${python}/bin/python3 ${./.}/private_pki.py ${../../../../../audi/priv/private_pki}";
      TimeoutStartSec = 60;
      MemoryMax = "256M";
      CapabilityBoundingSet = [];
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/inception" "/run/inception-public" ];
      RestrictAddressFamilies = [ "AF_UNIX" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}
