# @cc [owner:ghuntley,label:security] reviewed-fleet-network-sources
# Fleet-wide public-network grants MUST name reviewed fleet addresses (logical
# names in the shared fleet-addresses SOPS document, see fleet-addresses.nix)
# with a human-readable comment. Address literals, private keys and dynamic DNS
# names MUST NOT appear.
{
  overalls = {
    name = "overallsPrimary";
    comment = "Overalls fleet host";
  };
  dungarees = {
    name = "dungareesPrimary";
    comment = "Dungarees fleet host";
  };
  panterloons = {
    name = "panterloonsPrimary";
    comment = "Panterloons fleet host";
  };
}
