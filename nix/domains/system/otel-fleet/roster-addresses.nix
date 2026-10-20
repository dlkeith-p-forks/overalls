# Fleet tunnel addresses of a telemetry roster, in order: the central host is
# 10.90.0.1 and the worker 10.90.0.2 (enforced by the otel-fleet assertions).
hosts: builtins.genList (index: "10.90.0.${toString (index + 1)}") (builtins.length hosts)
