{ pkgs, hostFixture, imageSize }:
let
  config = (hostFixture.extendModules {
    modules = [ ({ lib, ... }: {
      disko.devices.disk = lib.genAttrs [ "system0" "system1" ] (_: {
        imageSize = lib.mkForce imageSize;
      });
    }) ];
  }).config;
  pool = "zroot";
  dataset = "${pool}/lilly";
  zfs = config.boot.zfs.package;
in
# @cc [owner:ghuntley,label:verification] fleet-storage-observed-identities
# Fixture identities MUST be read from the real prepared virtual pool, never
# invented as a substitute for filesystem binding. These images contain public
# configuration only; credentials and capacity observations arise at test runtime.
pkgs.lib.overrideDerivation config.system.build.diskoImages (previous: {
  name = "overalls-fleet-storage";
  buildCommand = previous.buildCommand + ''
    pool_guid="$(${zfs}/bin/zpool get -Hp -o value guid ${pkgs.lib.escapeShellArg pool})"
    dataset_guid="$(${zfs}/bin/zfs get -Hp -o value guid ${pkgs.lib.escapeShellArg dataset})"
    ${pkgs.jq}/bin/jq -n --arg pool "$pool_guid" --arg dataset "$dataset_guid" \
      --arg name ${pkgs.lib.escapeShellArg dataset} \
      '{backend: "zfs", zpool_guid: $pool, dataset_guid: $dataset, dataset: $name}' \
      > "$out/identity.json"
    ${zfs}/bin/zpool export ${pkgs.lib.escapeShellArg pool}
  '';
})
