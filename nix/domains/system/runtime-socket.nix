{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.runtimeSockets;
  unit = name: "overalls-runtime-socket-${name}";
in
{
  options.overalls.runtimeSockets = mkOption {
    default = {};
    description = "Socket units whose IPv4 ListenStream address is runtime data (for example a decrypted SOPS bundle output), keyed by the socket unit name without .socket. The socket's static listenStreams stay empty; a validating unit supplies the address as a runtime drop-in.";
    type = types.attrsOf (types.submodule {
      options = {
        addressFile = mkOption {
          type = types.strMatching "/run/[A-Za-z0-9_./-]+";
          description = "Runtime file holding the explicit IPv4 listen address.";
        };
        addressUnit = mkOption {
          type = types.strMatching "[a-zA-Z0-9_.@-]+\\.service";
          description = "Unit that publishes addressFile; the socket address follows it.";
        };
        port = mkOption { type = types.port; description = "Listen port on the runtime address."; };
      };
    });
  };

  config = lib.mkIf (cfg != {}) {
    # Without the drop-in the socket has no Listen setting and does not load,
    # so boot must not pull it in; the applying unit starts it. Ordering the
    # socket after that unit would cycle through sockets.target and basic.target.
    assertions = lib.mapAttrsToList (name: _: {
      assertion = config.systemd.sockets ? ${name}
        && config.systemd.sockets.${name}.listenStreams == []
        && config.systemd.sockets.${name}.wantedBy == [];
      message = "Runtime socket ${name} must be a declared socket without static listenStreams or wantedBy.";
    }) cfg;

    # @cc [owner:ghuntley,label:security;recovery] runtime-socket-address
    # A runtime socket MUST listen only on its validated explicit IPv4 address.
    # The address MUST arrive as a /run drop-in after its publishing unit, never
    # in the Nix store; a missing or malformed address MUST leave the socket
    # stopped rather than listening on a wildcard. Socket options such as
    # FreeBind stay with the declared unit.
    # Restarting the address unit (rotation) restarts this unit through
    # Requires=: stop withdraws the drop-in, start applies the new address.
    systemd.services = lib.mapAttrs' (name: socket: lib.nameValuePair (unit name) {
      description = "Apply the runtime listen address of ${name}.socket";
      after = [ socket.addressUnit ];
      requires = [ socket.addressUnit ];
      wantedBy = [ "multi-user.target" ];
      # Refused addresses must not exhaust a start limit that would then
      # block the corrected address.
      startLimitIntervalSec = 0;
      path = [ config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./runtime-socket.py}"
          "--socket" name "--address-file" socket.addressFile "--port" (toString socket.port) ];
        ExecStopPost = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./runtime-socket.py}"
          "--remove" "--socket" name ];
      };
    }) cfg;
  };
}
