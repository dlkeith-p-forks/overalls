# Cachix watch-store review

Overalls and Dungarees now enable the NixOS `cachix-watch-store` agent for the
`overalls` cache. A scoped token is delivered by the existing SSH-host-derived
SOPS preparation service and the upload unit requires that preparation. The
encrypted document is registered for both host recipients; no token is present
in evaluated Nix configuration. Evaluation proves service enablement and secret
paths. A live upload and token rotation have not been executed.
