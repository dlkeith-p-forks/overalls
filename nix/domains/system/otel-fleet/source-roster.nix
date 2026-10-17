# @cc [owner:ghuntley,label:reliability] candidate-enrolled-source-roster
# Missing or additional enrolled hosts MUST withhold candidate measurements.
# Guest-origin series MUST NOT satisfy the source roster.
service: let
  source = builtins.head (builtins.filter (s: s.id == service) (import ./objectives.nix));
  metric = ''overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"'';
in ''
  (count(${metric}}) == ${toString (builtins.length source.hosts)})
  ${builtins.concatStringsSep "" (builtins.map (host: ''
    and on() (count(${metric},host_name="${host}"}) == 1)
  '') source.hosts)}
''
