{ lib, pkgs }:
{
  options = {
    enable = lib.mkEnableOption "bounded encrypted OTP crash dumps";
    publicKeyFile = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/[^\n\r]+");
      default = null;
      description = "Operator RSA public key (at least 3072 bits). Keep its private key off-host.";
    };
  };
  launch = cfg: package: directory: command:
    if cfg.enable then "${pkgs.python3}/bin/python ${./runtime.py} start ${lib.escapeShellArg directory} ${lib.escapeShellArg (if cfg.publicKeyFile == null then "" else cfg.publicKeyFile)} ${package}/overalls-release.json ${pkgs.openssl}/bin/openssl ${command}"
    else command;
  finish = directory: "${pkgs.python3}/bin/python ${./runtime.py} finish ${directory}";
}
