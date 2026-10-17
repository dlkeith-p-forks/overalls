{ pkgs }:
let
  inputs = import ./inputs.nix;
  source = pkgs.fetchFromGitHub {
    owner = "microsoft";
    repo = "vscode";
    rev = inputs.sourceCommit;
    hash = inputs.sourceHash;
  };
  directories = builtins.fromJSON (builtins.readFile ./npm-directories.json);
in
pkgs.runCommand "overalls-vscode-web-npm-cache-${inputs.version}" {
  src = source;
  nativeBuildInputs = [ pkgs.prefetch-npm-deps pkgs.git pkgs.cacert ];
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = inputs.npmHash;
  FORCE_EMPTY_CACHE = "true";
  FORCE_GIT_DEPS = "true";
  npm_config_progress = "false";
  npm_config_cafile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
} ''
  runPhase unpackPhase
  mkdir -p "$out"
  ${pkgs.lib.concatMapStringsSep "\n" (directory: ''
    prefetch-npm-deps ${pkgs.lib.escapeShellArg "${directory}/package-lock.json"} "$out/${directory}"
  '') directories}
''
