# @cc [owner:ghuntley,label:security] fleet-address-names
# Every fleet public address MUST be named here by logical name and secret
# name only; the values live in the shared fleet-addresses SOPS document.
# Each host also declares its own uplink prefix and gateway in host.json.
{
  overallsPrimary = "OVERALLS_PRIMARY_IPV4";
  overallsService = "OVERALLS_SERVICE_IPV4";
  dungareesPrimary = "DUNGAREES_PRIMARY_IPV4";
  dungareesService = "DUNGAREES_SERVICE_IPV4";
  salopettesPrimary = "SALOPETTES_IPV4";
}
