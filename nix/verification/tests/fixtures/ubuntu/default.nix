{ packages }:
packages.mkUbuntuGuest {
  imageName = "ubuntu-customization-fixture";
  packages = [ "hello" ];
  packageLock = ./packages.lock.json;
  privateServiceRoots = [ ./ca.crt ];
  files."/etc/myapp/config.json" = { source = ./config.json; mode = "0640"; };
}
