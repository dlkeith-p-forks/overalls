{ module, packages }:
{ config, lib, pkgs, ... }:
{
  imports = [ (import ./role-node.nix { inherit module packages; }) ];
  boot.supportedFilesystems = lib.optionals config.services.lilly.enable [ "zfs" ];
  boot.extraModprobeConfig = lib.mkIf config.services.lilly.enable "options zfs zfs_arc_max=268435456";
  systemd.services.zfs-zed.enable = lib.mkIf config.services.lilly.enable false;
  virtualisation.emptyDiskImages = lib.mkIf config.services.lilly.enable [ 1024 ];
  services.openssh.enable = lib.mkIf config.services.lilly.enable true;
  # @cc [owner:ghuntley,label:verification;storage] service-roles-native-pool-binding
  # This role check MUST create a real native ZFS pool and bind Lilly's private
  # runtime and transfer configs to its observed GUIDs before asserting host
  # ownership. Fixed placeholder GUIDs MUST NOT stand in for a mounted pool.
  systemd.services.service-roles-storage = lib.mkIf config.services.lilly.enable {
    before = [ "lilly.service" ];
    path = [ config.boot.zfs.package ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      zpool create -f -O mountpoint=none -O compression=lz4 tank /dev/vdb
      zfs create -o mountpoint=/pool tank/lilly
      pool_guid="$(zpool get -Hp -o value guid tank)"
      dataset_guid="$(zfs get -Hp -o value guid tank/lilly)"
      install -d -m 0700 /run/lilly-transfer
      ${pkgs.jq}/bin/jq --arg pool "$pool_guid" --arg dataset "$dataset_guid" \
        '.pools[0].filesystem_id = ("zfs:" + $pool + ":" + $dataset) |
         .pools[0].storage.zpool_guid = $pool | .pools[0].storage.dataset_guid = $dataset' \
        /etc/lilly-transfer.json > /run/lilly-transfer/config.json.new
      chmod 0600 /run/lilly-transfer/config.json.new
      mv /run/lilly-transfer/config.json.new /run/lilly-transfer/config.json
    '';
  };
  services.lillyTransfer.configurationFile = lib.mkIf config.services.lilly.enable "/run/lilly-transfer/config.json";
  systemd.services.lilly-transfer-sshd = lib.mkIf config.services.lilly.enable {
    requires = [ "service-roles-storage.service" ];
    after = [ "service-roles-storage.service" ];
  };
  systemd.services.lilly = lib.mkIf config.services.lilly.enable {
    requires = [ "service-roles-storage.service" ];
    after = [ "service-roles-storage.service" ];
    preStart = lib.mkAfter ''
      pool_guid="$(zpool get -Hp -o value guid tank)"
      dataset_guid="$(zfs get -Hp -o value guid tank/lilly)"
      ${pkgs.jq}/bin/jq --arg pool "$pool_guid" --arg dataset "$dataset_guid" \
        '.pools[0].filesystem_id = ("zfs:" + $pool + ":" + $dataset) |
         .pools[0].storage.zpool_guid = $pool | .pools[0].storage.dataset_guid = $dataset' \
        /run/lilly-release/config.json > /run/lilly-release/config.json.new
      chmod 0600 /run/lilly-release/config.json.new
      mv /run/lilly-release/config.json.new /run/lilly-release/config.json
    '';
  };
  services.galileo = lib.mkIf config.services.lilly.enable {
    secretsFile = "/run/overalls-test/galileo.enc.json";
    cpuCores = 1;
    memoryMiB = 512;
  };
  services.ziggy = lib.mkIf config.services.lilly.enable {
    secretsFile = "/run/overalls-test/ziggy.enc.json";
    enabledProviders = [ "openai" ];
    openaiOrigin = "http://127.0.0.1:8080";
    cpuCores = 1;
    memoryMiB = 512;
  };
  # @cc [owner:ghuntley,label:verification;security] service-roles-private-secrets
  # Required Galileo and Ziggy credentials MUST be sealed at runtime for the
  # VM host identity and prepared by real SecretSpec/SOPS units before either
  # service starts. No fixture plaintext may enter the Nix store or logs.
  systemd.services.overalls-test-fixture = lib.mkIf config.services.lilly.enable {
    after = [ "sshd-keygen.service" ];
    requires = [ "sshd-keygen.service" ];
    postStart = ''
      ${pkgs.python3}/bin/python3 ${../machines/service-roles/seal.py} \
        ${packages.secretTools.sops}/bin/sops \
        ${packages.secretTools.ssh-to-age}/bin/ssh-to-age
    '';
  };
  systemd.services.overalls-secrets-galileo = lib.mkIf config.services.lilly.enable {
    after = [ "overalls-test-fixture.service" ];
    requires = [ "overalls-test-fixture.service" ];
  };
  systemd.services.overalls-secrets-ziggy = lib.mkIf config.services.lilly.enable {
    after = [ "overalls-test-fixture.service" ];
    requires = [ "overalls-test-fixture.service" ];
  };
}
