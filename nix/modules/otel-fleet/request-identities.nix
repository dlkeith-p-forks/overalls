# @cc [owner:ghuntley,label:security;deployment] request-account-bounded-identity
# Every recorder instance MUST have distinct recorder, RPC, reader and exporter
# roles with Unix account/group names shorter than 32 characters. Names MUST
# depend only on the configured instance, never on producer request data.
let
  suffix = name: builtins.substring 0 20 (builtins.hashString "sha256" name);
in {
  recorderUser = name: "ksr-${suffix name}";
  rpcGroup = name: "ksr-${suffix name}-rpc";
  readerGroup = name: "ksr-${suffix name}-read";
  exporterUser = name: "ksx-${suffix name}";
}
