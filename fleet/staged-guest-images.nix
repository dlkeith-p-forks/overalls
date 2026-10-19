{ overallsPackages }:
let
  selected = import ./guest-images.nix { inherit overallsPackages; };
  retained = [
    { name = "FreeBSD 14.3 retained"; package = overallsPackages.legacyFreebsdGuest; }
    { name = "OmniOS r151050 retained"; package = overallsPackages.legacyOmniosGuest; }
  ];
  unique = entries: builtins.foldl' (result: entry:
    if builtins.any (previous: toString previous.package == toString entry.package) result
    then result else result ++ [ entry ]
  ) [ ] entries;
in
# @cc [owner:ghuntley,label:deployment;recovery] fleet-retained-native-staging
# Every selected catalog package MUST remain staged. Explicit immutable native
# history MUST additionally remain staged for commands already bound to an old
# image ID. Deduplication MUST compare exact package paths, never OS aliases;
# staging alone MUST NOT register a new catalog selection or grant capabilities.
unique (selected ++ retained)
