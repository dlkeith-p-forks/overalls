{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-service-roles";
  requiredFeatures.nested-kvm = true;
  defaults = import ../../support/native-role-node.nix { inherit module packages; };
  nodes = {
    neither = {};
    marshall = { services.marshall.enable = true; };
    lilly = { services.lilly.enable = true; };
    # @cc [owner:ghuntley,label:verification] colocated-reference-service-count
    # The combined role MUST boot three distinct Marshall instances alongside
    # Lilly and proxy every backend. Reduced fixture budgets MUST remain explicit.
    combined = { lib, ... }: {
      virtualisation.memorySize = lib.mkForce 4096;
      services.marshall = {
        enable = true;
        cpuCores = lib.mkForce 2;
        memoryMiB = lib.mkForce 2304;
        instances = lib.genAttrs [ "combined-two" "combined-three" ] (name: {
          port = if name == "combined-two" then 4444 else 4445;
          certificateFile = "/run/overalls-test/tls.crt";
          keyFile = "/run/overalls-test/tls.key";
        });
      };
      services.lilly.enable = true;
      services.marshallProxy = {
        enable = true;
        backends = lib.mkForce (lib.genAttrs [ "one" "two" "three" ] (name: {
          address = "127.0.0.1";
          port = { one = 4443; two = 4444; three = 4445; }.${name};
          serverName = "localhost";
        }));
      };
    };
  };
  testScript = builtins.readFile ./driver.py;
}
