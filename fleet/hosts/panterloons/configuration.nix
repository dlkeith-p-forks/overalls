{ ... }:
{
  # Panterloons is a separate copy of the Overalls deployment (ADR-0246) with
  # its own database, secrets and fleet tunnel; Dungarees is its worker.
  imports = [ ../overalls/configuration.nix ];
  overalls.controlPlaneHost = {
    name = "panterloons";
    adminAddress = "100.98.214.120";
    otelWorker = "dungarees";
    # Its own Marshall has not yet issued Porsche, Audi, Ziggy or Galileo
    # credentials.
    bootstrap = true;
  };
}
