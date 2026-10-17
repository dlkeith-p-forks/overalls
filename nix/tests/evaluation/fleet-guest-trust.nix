{ pkgs, variants }:
let
  inherit (pkgs) lib;
  base = [ "storage-failures" "idempotency" "capacity" "network" "updates" "terminal" "control-plane-recovery" "provisioner-recovery" "lifecycle" "staleness" "credential-revocation" ];
  routes = {
    fleet = base;
    porsche-fleet = [ "porsche" ] ++ base;
    cloning-fleet = [ "porsche" ];
    brady-fleet = [ "brady" ];
    customer-isolation-fleet = [ "customer-setup" "network" "updates" "provisioner-recovery" "customer-recovery" ];
    relocation-fleet = [ "relocation" "relocation-failures" ];
    ubuntu-fleet = [ "porsche" "relocation" ];
  };
  ubuntuImages = variants.ubuntu-fleet.nodes.l1.services.lilly.images;
  expectedImages = name: if name == "ubuntu-fleet" then ubuntuImages
    else [ (builtins.elemAt ubuntuImages 1) ];
  inspect = name: fragments:
    let
      test = variants.${name};
      script = test.config.testScript;
      # lib.hasInfix is regex-based and overflows the evaluator stack on whole
      # composed scripts; replaceStrings is a plain substring scan.
      includes = needle: haystack:
        builtins.stringLength (builtins.replaceStrings [ needle ] [ "" ] haystack)
        != builtins.stringLength haystack;
      contains = fragment: includes (builtins.readFile (../machines/fleet/scenarios + "/${fragment}.py")) script;
      hosts = map (host: test.nodes.${host}) [ "l1" "l2" ];
      roots = map (host: builtins.length host.services.lilly.guestTrustRoots) hosts;
      images = map (host: host.services.lilly.images) hosts;
      signers = map (node: test.nodes.${node}) [ "m1" "m2" "m3" ];
      hostCa = lib.removeSuffix "\n" (builtins.readFile ../fixtures/ssh-host-ca/key.pub);
    in
    assert test.config.name == "overalls-${name}";
    assert lib.all contains fragments;
    assert contains "boot-trust-services";
    assert !contains "audi";
    assert roots == [ 3 4 ];
    # Clone journeys use a 32 GiB fleet pool quota (bce13223); others use 16 GiB.
    assert includes "storage_budget = ${toString ((if name == "cloning-fleet" then 32 else 16) * 1073741824)}\n" script;
    assert lib.all (host: host.services.audi.enable && host.services.audiPrivate.enable && host.services.lilly.privateServices.enable) hosts;
    assert lib.all (host: builtins.elem "lilly.service" host.systemd.services.audi-private.wantedBy) hosts;
    assert test.nodes.m2.services.audiDns.enable && test.nodes.m3.services.audiDns.enable;
    assert lib.all (node:
      node.services.marshall.sshHostCa.publicKey == hostCa
      && node.services.marshall.sshHostCa.keyFile == "/var/lib/overalls-fleet/ssh-host-ca"
      && lib.hasInfix "install -m 0600" node.systemd.services.fleet-credentials.preStart
      && lib.hasInfix "/var/lib/overalls-fleet/ssh-host-ca" node.systemd.services.fleet-credentials.preStart
    ) signers;
    assert builtins.length ubuntuImages == 2;
    assert images == [ (expectedImages name) (expectedImages name) ];
    {
      evaluated_name = test.config.name;
      feature_fragments = fragments;
      shared_trust_bootstrap = true;
      audi_feature_fragment = false;
      inherit roots images;
      private_services = true;
      ssh_host_ca_signers = true;
    };
in
# @cc [owner:ghuntley,label:verification;security] fleet-prerequisites-preserve-feature-routes
# Repairing trust prerequisites MUST preserve all seven historical check names
# and feature fragments. Both real host configurations MUST require nonempty
# roots, private services and SSH host CA signers; assertions do not establish
# native acceptance.
pkgs.writeText "overalls-fleet-guest-trust-configuration.json"
  (builtins.toJSON (builtins.mapAttrs inspect routes))
