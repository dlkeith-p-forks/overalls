let
  candidates = import ./candidate-sources.nix;
  hosts = {
    brady = [ "overalls" "dungarees" ];
    galileo = [ "overalls" "dungarees" ];
    enrico = [ "overalls" ];
    porsche = [ "overalls" ];
    ziggy = [ "overalls" "dungarees" ];
    audi_private = [ "overalls" "dungarees" ];
    audi_dns = [ "overalls" "dungarees" ];
    marshall_web = [ "overalls" ];
    audi_ssh = [ "overalls" "dungarees" ];
    underclass_proxy = [ "overalls" "dungarees" ];
    marshall_ready = [ "overalls" ];
    lilly_physical = [ "overalls" ];
    porsche_physical = [ "overalls" ];
    porsche_clone = [ "overalls" ];
    porsche_relocate = [ "overalls" ];
    porsche_retry = [ "overalls" ];
    porsche_cancel = [ "overalls" ];
    vscode_browser_nixos = [ "overalls" ];
    vscode_browser_ubuntu = [ "overalls" ];
  };
in
# @cc [owner:ghuntley,label:reliability;deployment] provisional-objective-roster
# A seven-day application objective MUST name every enrolled source host and
# remain provisional until source crash accounting and its actual journey have
# been reviewed. A placement change MUST update this roster in the same change.
[
  { id = "collectors"; target = 0.999; kind = "collector"; minRequests = 0; hosts = [ "overalls" "dungarees" ]; }
  { id = "ingress"; target = 0.995; kind = "ingress"; minRequests = 100; hosts = [ "overalls" "dungarees" ]; }
] ++ builtins.map (source: {
  id = source.service;
  target = 0.99;
  kind = "candidate";
  minRequests = 100;
  hosts = hosts.${source.service};
}) candidates ++ [
  { id = "underclass_monitor"; target = 0.99; kind = "monitor"; minRequests = 0; hosts = [ "overalls" "dungarees" ]; }
]
