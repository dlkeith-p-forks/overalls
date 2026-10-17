{ pkgs }:
let
  python = pkgs.python313.withPackages (packages: [ packages.playwright ]);
  fontconfig = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
in pkgs.writeShellApplication {
  name = "overalls-browser-editor-journey";
  runtimeInputs = [ python ];
  # @cc [owner:ghuntley,label:reliability;build] browser-pinned-headless-fonts
  # Browser journeys MUST have a pinned font configuration and font tree even on
  # headless hosts. Host desktop configuration MUST NOT establish this capability.
  text = ''
    export FONTCONFIG_FILE=${fontconfig}
    exec ${python}/bin/python3 ${./browser_journey.py} "$@"
  '';
}
