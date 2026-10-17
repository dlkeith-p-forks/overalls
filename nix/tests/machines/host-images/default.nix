{ pkgs, images }:
pkgs.testers.runNixOSTest {
  name = "overalls-host-images";
  nodes = {};
  requiredFeatures.kvm = true;
  globalTimeout = 1200;
  testScript = ''
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    firmware = "${pkgs.OVMF.firmware}"
    variables = "${pkgs.OVMF.variables}"
    ssh_keyscan = "${pkgs.openssh}/bin/ssh-keyscan"
    images = "${images}"
  '' + builtins.readFile ./driver.py;
}
