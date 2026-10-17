# @cc [owner:ghuntley,label:security] reviewed-fleet-network-sources
# Fleet-wide public-network grants MUST use reviewed IPv4 addresses with a
# human-readable comment. Private keys and dynamic DNS names MUST NOT appear.
{
  overalls = {
    address = "136.243.69.55";
    comment = "Overalls fleet host";
  };
  dungarees = {
    address = "136.243.69.35";
    comment = "Dungarees fleet host";
  };
}
