# Mila S2: Porsche terminal attach (2026-10-19)

Scope: [ADR-0223](../decisions/0223-porsche-terminal-attach.md), with
[ADR-0019](../decisions/0019-terminal-session-and-writer-authority.md) and
[ADR-0083](../decisions/0083-terminal-host-stream-and-registry.md) preserved.
Reviewed against the uncommitted working tree on branch `feat/mila-terminal`,
fast-forwarded to integration commit `8e67caab` (from `e4259258`) with the S2
changes reapplied three-way.

## Findings

1. **Boundary:** No new Ash domain, resource, host or service. Terminal
   tickets gain a nullable `ssh_session_id`. The new surface is one route on
   the existing fleet endpoint, `GET /api/terminal-gateway/v1/stream`. It
   upgrades into the existing `Marshall.Terminal.Viewer`, so attach shares the
   browser's session registry, replay, writer authority and host stream.
2. **Identity:** Before any socket exists, the stream needs the Porsche gateway
   bearer, the attaching connection's live SSH session token, and a
   single-use ticket bound to that SSH session. A browser ticket refuses on
   this route, and an SSH-bound ticket refuses on the browser route.
3. **Authorization:** The ticket mode comes from `Terminal.Authority.ticket/3`.
   It is writable only for the owner with current write access, and only
   without `--read-only`, so it never escalates. The viewer rechecks
   `SSH.Authority.session_live?/2` every 5 seconds and on `:ssh_session`
   control hints. Failures map as follows:
   - a refused credential closes 4001 (exit 3);
   - an inconclusive check closes 1011 (exit 5).
4. **Transport and capacity:** Porsche relays input only after a writable
   grant, within `TerminalWindow` credit (16 frames or 256 KiB), in frames of
   at most 16 KiB. Its input queue is bounded at 1 MiB. Output is acknowledged
   only after `:ssh_connection.send/5` returns, so Marshall's output credit
   never runs ahead of the SSH client. Silence beyond 15 seconds is a
   transport failure.
5. **Privacy:** Attachments run under `Porsche.Terminal.Attachments`, a
   DynamicSupervisor, as `porsche_private` processes with redacted status.
   - Only catalogued events with enum metadata are emitted:
     `porsche.terminal_attached`, `porsche.terminal_detached` and
     `terminal.attached` with `origin`.
   - Tickets, tokens and terminal bytes are never logged or printed.
6. **Gap: native evidence:** The `porsche-terminal-fleet` machine test
   evaluates and its driver type-checks, but no run has completed:
   - Run 1 failed in its own setup: the guest host's terminal stream was
     still registering, and the fixture did not retry. Fixed with
     readiness-only retries.
   - Run 2 failed earlier, in the already-existing Porsche browser key step
     (`owner login connection`). Host load average was about 55 on 32 cores,
     and the step passed in run 1.
7. **Gap: Mila:** Mila does not yet drive `terminal attach`.

## Recorded runs

All runs use the pinned `devenv shell` toolchain.

| Command | Tree | Result |
| --- | --- | --- |
| `mix test test/terminal_attach_test.exs test/ssh_command_test.exs` (protocol) | `8e67caab` + S2 | **19 passed** |
| `mix test --warnings-as-errors` (porsche) | `8e67caab` + S2 | **122 passed** |
| `mix covenant.check --no-run`, `mix dialyzer --force-check`, `mix format --check-formatted`, `mix logging.check` (porsche) | `8e67caab` + S2 | all passed |
| `mix compile --warnings-as-errors`, `mix logging.check` (marshall) | `8e67caab` + S2 | passed |
| `mix test test/marshall_web/ssh_terminal_attach_test.exs` (marshall) | `e4259258` + S2 | **7 passed** |
| `mix test --warnings-as-errors` (protocol) | `e4259258` + S2 | 387/389; both failures are in `native_admission_test.exs`, which also fails on unmodified `e4259258` (5/7) |
| `mix dialyzer`, `mix covenant.check --no-run` (protocol) | `e4259258` + S2 | passed |
| `elixir scripts/check_adrs.exs` | `e4259258` + S2 | passed (212 decisions) |
| `nix eval .#checks.x86_64-linux.porsche-terminal-fleet.driver.drvPath` | `e4259258` + S2 | evaluated |

Not recorded: the full Marshall suite, the Marshall Dialyzer run, the Lilly
consumer check and a passing `porsche-terminal-fleet` run.
- An earlier full Marshall run lost its Repo mid-suite (411/1944). The
  cause was not identified before the rerun was stopped.
- The earlier Marshall Dialyzer run reported two `call_without_opaque`
  warnings in `lib/marshall_web/gettext.ex`; S2 does not touch that file.
