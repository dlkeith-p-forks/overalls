# @cc [owner:ghuntley,label:security;verification] hldd-public-topology-projection
# Documentation MUST project only public placement facts. Never serialize whole
# service configurations, environments, credentials or secret file contents.
{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  inventory = (import ../../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  roles = [ "marshall" "marshallProxy" "postgresql" "lilly" "lillyTransfer"
    "porsche" "audi" "audiDns" "audiPrivate" "brady" "ziggy" "galileo"
    "enrico" "peach" "susan" "underclass" "overallsFleetExporter" "overallsBackups" "overallsAutoUpdate"
    "overallsLogging" "overallsLogStore" "overallsOtelGuest" "overallsOtelFleet"
    "opentelemetry-collector" "prometheus" "tempo" "grafana" ];
in map (name:
  let
    enrolled = builtins.hasAttr name flake.nixosConfigurations;
    c = flake.nixosConfigurations.${if enrolled then name else "${name}-base"}.config;
    requestInstances = lib.filterAttrs (_: instance: instance.enable)
      (c.services.overallsRequestRecorder.instances or {});
    requestRoles = builtins.listToAttrs (map (source: {
      name = source; value = true;
    }) (map (instance: instance.source) (builtins.attrValues requestInstances)));
  in {
    inherit name enrolled;
    services = builtins.filter (role: c.services.${role}.enable or false) roles
      ++ lib.optionals ((c.services.overallsOtelFleet.enable or false) &&
        (c.services.overallsOtelFleet.traceSpool.enable or false))
        (map (producer: "overalls-trace-${producer.instance}")
          (c.services.overallsOtelFleet.traceSpool.producers or []))
      ++ lib.optional ((c.services.brady.enable or false) && (c.services.overallsOtelFleet.enable or false)) "bradySloExporter"
      ++ lib.optional ((c.services.galileo.enable or false) && (c.services.overallsOtelFleet.enable or false)) "galileoSloExporter"
      ++ lib.optional ((c.services.enrico.enable or false) && (c.services.overallsOtelFleet.enable or false)) "enricoSloExporter"
      ++ lib.optional ((c.services.porsche.enable or false) && (c.services.overallsOtelFleet.enable or false)) "porscheSloExporter"
      ++ lib.optional ((c.services.ziggy.enable or false) && (c.services.overallsOtelFleet.enable or false)) "ziggySloExporter"
      ++ lib.optional ((c.services.audiPrivate.enable or false) && (c.services.overallsOtelFleet.enable or false)) "audiPrivateSloExporter"
      ++ lib.optional ((c.services.audiDns.enable or false) && (c.services.overallsOtelFleet.enable or false)) "audiDnsSloExporter"
      ++ lib.optional ((c.services.audi.enable or false) && (c.services.overallsOtelFleet.enable or false)) "audiSshSloExporter"
      ++ lib.optional ((c.services.underclass.enable or false) && (c.services.overallsOtelFleet.enable or false)) "underclassMonitorProbe"
      ++ lib.optional ((c.services.underclass.enable or false) && (c.services.overallsOtelFleet.enable or false)) "underclassProxySloExporter"
      ++ lib.optional ((c.services.underclass.enable or false) && (c.services.underclass.egress.enable or false)) "underclassEgress"
      ++ lib.optional ((c.services.marshall.enable or false) && (c.services.overallsOtelFleet.enable or false)) "marshallSloExporter"
      ++ lib.optional (c.services.overallsOtelFleet.publicGrafana.enable or false) "grafanaPublicProxy"
      ++ lib.optional (c.services.prometheus.alertmanager.enable or false) "alertmanager"
      ++ lib.optional ((c.services.overallsOtelFleet.enable or false) && (c.services.overallsOtelFleet.role or "worker") == "central") "telemetryStorageProbe"
      ++ lib.optional (requestRoles ? brady) "bradyRequestRecorder"
      ++ lib.optional (requestRoles ? galileo) "galileoRequestRecorder"
      ++ lib.optional (requestRoles ? enrico) "enricoRequestRecorder"
      ++ lib.optional (requestRoles ? porsche) "porscheRequestRecorder"
      ++ lib.optional (requestRoles ? audi_private) "audiPrivateRequestRecorder"
      ++ lib.optional (requestRoles ? audi_dns) "audiDnsRequestRecorder"
      ++ lib.optional (requestRoles ? audi_ssh) "audiSshRequestRecorder"
      ++ lib.optional (requestRoles ? marshall_web) "marshallRequestRecorder"
      ++ lib.optional (requestRoles ? vscode_browser_nixos) "vscodeBrowserNixosRequestRecorder"
      ++ lib.optional (requestRoles ? vscode_browser_ubuntu) "vscodeBrowserUbuntuRequestRecorder"
      ++ lib.optional (c.systemd.services.overalls-vscode-browser-nixos.enable or false) "vscodeBrowserNixosProbe"
      ++ lib.optional (c.systemd.services.overalls-vscode-browser-ubuntu.enable or false) "vscodeBrowserUbuntuProbe"
      ++ lib.optional (c.systemd.services.overalls-request-vscode-browser-nixos-exporter.enable or false) "vscodeBrowserNixosExporter"
      ++ lib.optional (c.systemd.services.overalls-request-vscode-browser-ubuntu-exporter.enable or false) "vscodeBrowserUbuntuExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-marshall_ready-exporter.enable or false) "marshallReadySloExporter"
      ++ lib.optional (c.systemd.services.lilly-hostd.enable or false) "lillyHostd"
      ++ lib.optional (c.systemd.services.marshall-overalls-lilly_physical-exporter.enable or false) "lillyPhysicalSloExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-porsche_physical-exporter.enable or false) "porschePhysicalSloExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-porsche_clone-exporter.enable or false) "porscheCloneSloExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-porsche_relocate-exporter.enable or false) "porscheRelocateSloExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-porsche_retry-exporter.enable or false) "porscheRetrySloExporter"
      ++ lib.optional (c.systemd.services.marshall-overalls-porsche_cancel-exporter.enable or false) "porscheCancelSloExporter";
    marshallInstances = if c.services.marshall.enable then builtins.attrNames c.services.marshall.instances else [];
    fleetAddress = if c.overalls.fleetNetwork.enable then c.overalls.fleetNetwork.address else null;
    fleetPeers = if c.overalls.fleetNetwork.enable then builtins.attrNames c.overalls.fleetNetwork.peers else [];
    adminSshPorts = c.services.openssh.ports;
  }
) (builtins.attrNames inventory)
