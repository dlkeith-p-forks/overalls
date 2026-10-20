# Mila native rewrite architecture review (2026-10-20)

## Scope

This review covers the accepted transition in ADR-0249 from the Flutter client
to native platform shells around a Rust core.

## Findings

The boundary is sound for the current milestone: `mila/rust` owns typed protocol
models, cryptographic primitives and mutation tracking, while each native target
has a separate adapter. Nix and CI build the Rust workspace and run its Hegel
properties. The adapters currently are scaffolds, so this review does not claim
transport, key custody, push, terminal or release parity.

## Required follow-up

Implement the Porsche transport and storage traits in Rust, add shared fixtures
for host certificates, push/poke, terminal attach and machine state, and record
native-host build and lifecycle evidence before deleting Flutter. Update the
HLDD coverage and security scenarios when those capabilities become shipped.

## Decision

Approved as a partial architecture implementation. No deployment topology or
Marshall authority changes are introduced by the scaffolds.
