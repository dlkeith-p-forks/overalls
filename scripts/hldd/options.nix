# Declaration defaults only: no enrolled host configuration or runtime secrets.
{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  evaluated = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ flake.nixosModules.default ];
  };
  entries = lib.optionAttrSetToDocList evaluated.options;
  safely = value: let result = builtins.tryEval (builtins.deepSeq value value);
    in if result.success then result.value else { _type = "literalExpression"; text = "<derived from required configuration>"; };
  owned = o: lib.hasPrefix "overalls." o.name ||
    builtins.match "services\\.(overalls[^.]*|marshall[^.]*|lilly[^.]*|audi[^.]*|brady|porsche|ziggy|galileo|enrico|underclass)\\..*" o.name != null;
in map (o: {
  inherit (o) name type;
  description = if (o.description or null) == null then "No additional description is declared by the module." else o.description;
  default = safely (o.default or null);
  example = safely (o.example or null);
}) (builtins.filter owned entries)
