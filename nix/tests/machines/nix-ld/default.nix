{ pkgs }:
let
  inherit (pkgs) lib;
  unpatchedHello = pkgs.runCommand "unpatched-dynamic-hello" {
    nativeBuildInputs = [ pkgs.gcc pkgs.patchelf ];
    dontFixup = true;
  } ''
    cat > hello.c <<'EOF'
    #include <stdio.h>
    int main(void) {
      puts("overalls-dynamic-hello");
      return 0;
    }
    EOF
    gcc -o hello hello.c
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 hello
    mkdir -p $out/bin
    cp hello $out/bin/unpatched-dynamic-hello
  '';
in
pkgs.testers.runNixOSTest {
  name = "overalls-nix-ld";
  defaults = {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 512;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    environment.systemPackages = [ unpatchedHello ];
  };
  nodes = {
    enabled.programs.nix-ld.enable = true;
    disabled = {};
  };
  testScript = builtins.readFile ./driver.py;
}
