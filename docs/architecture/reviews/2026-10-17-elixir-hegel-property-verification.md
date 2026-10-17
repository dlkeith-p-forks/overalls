# Elixir Hegel property verification review

## Scope and impact

This review covers migrating the Elixir property suite from StreamData to the
pinned Hegel binding and adding model/history and controlled-concurrency APIs.
The change is confined to test dependencies and test support. It adds no Ash
domain, resource, protocol, persistence, authorization, host, or deployment
boundary. ADR-0191 records the accepted verification policy.

## Required evidence

Every migrated property must have bounded generators, a stable seed, replayable
case data, and redacted failure output. Fixture-backed properties must perform
per-case setup and teardown, including process, SQL sandbox, socket, and
supervision cleanup. Stateful properties must name the model and oracle; pooled
or concurrent properties must record the schedule boundary and must not claim
linearizability without a model check.

The normal application gates remain authoritative: compiler, ExUnit, Dialyzer,
contracts, logging, ADR and HLDD checks. Protocol changes require both Marshall
and Lilly consumer gates. Native Hegel smoke tests verify load, replay, shrink,
redaction, task cleanup, and state-machine behavior before migration results are
recorded.

## Limits and gaps

BEAM Hegel execution cannot establish native isolation, KVM behavior, physical
recovery, or production deployment. Those claims remain covered by NixOS and
native suites. A dependency declaration or unexecuted property is not evidence
of passing verification. Inception failures remain out of scope under the root
repository guidance.
