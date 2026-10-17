# Nix domain layout review

This change reorganizes Nix implementation, fixture and verification paths and
renames flake output leaves. It does not change Ash ownership, runtime service
behavior, protocols, persistence, authorization, isolation, capacity accounting,
or recovery decisions. Existing contracts remain in force and move with their
owned source trees. The new flake names are intentionally atomic; all repository
consumers and documentation use the new names.

Validation is limited to Nix evaluation and repository static checks when native
machine execution is unavailable. No architecture decision is superseded.
