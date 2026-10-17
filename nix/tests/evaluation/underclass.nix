{ pkgs, nixpkgs, module }:
let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      module
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      }
      extra
    ];
  }).config;
  bare = evaluate { };
  enabled = evaluate {
    services.tailscale.enable = true;
    services.underclass = {
      enable = true;
      environmentFile = "/run/overalls-secrets/underclass/environment";
      secretUnits = [ "overalls-secrets-underclass.service" ];
    };
  };
  noTailscale = evaluate { services.underclass.enable = true; };
  service = enabled.systemd.services.underclass;
  publication = enabled.systemd.services.underclass-tailscale-serve;

  # @cc [owner:ghuntley,label:verification] underclass-configuration-check
  # This check MUST verify opt-in reuse, loopback-only execution, runtime secret
  # ordering, bounded hardening and tailnet-only publication without claiming a
  # live tailnet or provider account.
  cases = {
    optIn = !bare.services.underclass.enable && !(bare.systemd.services ? underclass);
    hostCommands = builtins.elem enabled.services.underclass.package enabled.environment.systemPackages;
    loopbackOnly = service.serviceConfig.ExecStart
      == "${lib.getExe enabled.services.underclass.package} serve --bind 127.0.0.1:8080"
      && enabled.networking.firewall.allowedTCPPorts == [ ];
    runtimeSecrets = service.serviceConfig.EnvironmentFile
      == "/run/overalls-secrets/underclass/environment"
      && lib.hasInfix ''test "$UNDERCLASS_PROXY_KEY" != "$UNDERCLASS_UI_TOKEN"'' service.serviceConfig.ExecStartPre
      && builtins.elem "overalls-secrets-underclass.service" service.requires
      && builtins.elem "overalls-secrets-underclass.service" service.after;
    bounded = service.serviceConfig.DynamicUser
      && service.serviceConfig.StateDirectory == "underclass"
      && service.serviceConfig.RuntimeDirectory == "underclass"
      && service.serviceConfig.RuntimeDirectoryMode == "0755"
      && service.environment.UNDERCLASS_MONITOR_SOCKET == "/run/underclass/monitor.sock"
      && service.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" ]
      && service.serviceConfig.MemoryMax == "1G"
      && service.serviceConfig.CPUQuota == "200%"
      && service.serviceConfig.TasksMax == 512
      && service.serviceConfig.LimitNOFILE == 8192;
    tailnetOnly = lib.hasInfix " serve --yes --https=443 http://127.0.0.1:8080"
      publication.serviceConfig.ExecStart
      && !(lib.hasInfix " --bg " publication.serviceConfig.ExecStart)
      && !(lib.hasInfix "funnel" publication.serviceConfig.ExecStart)
      && publication.serviceConfig.Type == "exec"
      && publication.serviceConfig.Restart == "always"
      && !(publication.serviceConfig ? ExecStop)
      && builtins.elem "tailscaled.service" publication.requires
      && builtins.elem "underclass.service" publication.requires;
    tailscaleRequired = !(lib.all (item: item.assertion) noTailscale.assertions);
  };
  failed = builtins.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == [ ]) "Underclass configuration checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-underclass-configuration-check.json" (builtins.toJSON cases)
