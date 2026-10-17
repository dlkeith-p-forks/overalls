{ pkgs }:
let python = pkgs.python3.withPackages (p: [ p.aiohttp ]);
in
# @cc [owner:ghuntley,label:verification] acme-lookup-bounded-network-check
# Exercise the actual lookup implementation against isolated HTTP responders;
# these checks do not establish cross-machine firewall or ACME acceptance.
pkgs.runCommand "overalls-acme-lookup-check" { nativeBuildInputs = [ python ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python -W error ${./acme-lookup.py} ${../../modules/acme/lookup.py} ${../../modules/acme/lego.py}
  touch $out
''
