# marshall Contract

## Purpose

This Contract records executable, evidence-backed obligations for the `marshall` Mix project. It complements the repository's uppercase `CONTRACTS` scopes, architecture decisions, and native verification records.

## Scope

The Contract covers the Elixir modules listed by its components. Native helpers, physical isolation, multi-host behavior, browser acceptance, and production deployment remain governed by their existing evidence.

## Environment facts

The project uses the repository-pinned Elixir runtime and Covenant v0.2.0 as a development/test-only dependency.

## Known limits

A passing Covenant suite proves only the tagged Elixir checks that ran. It does not replace Dialyzer, native, NixOS, browser, distributed, or production acceptance.
