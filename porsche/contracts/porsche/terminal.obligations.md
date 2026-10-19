---
modules: [Porsche.Terminal.Attachment, Porsche.Terminal.Credit]
---

# Terminal obligations

## Purpose

SSH `terminal attach` (ADR-0223) relays a shared terminal session over Marshall's gateway stream. These obligations cover the BEAM-observable input and output accounting; native SSH, guest and journal-privacy evidence remains in the `porsche-terminal-fleet` machine test and the repository's `CONTRACTS`.

### porsche.terminal.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### porsche.terminal.I2 — Read-only attaches never release input
- **scope:** `Porsche.Terminal.Credit.push/2`, `grant/2` and `take/1`
- **must:** A requested or granted read-only attachment MUST release no input frame and MUST report every byte as discarded; a writable grant MUST release queued input in order within TerminalWindow credit.
- **kind:** security
- **status:** active

### porsche.terminal.I3 — Output receipts count only delivered frames
- **scope:** `Porsche.Terminal.Credit.delivered/2`
- **must:** The cumulative output receipt MUST advance by exactly one frame and its size per locally delivered frame, so Marshall's output credit never runs ahead of the SSH client.
- **kind:** security
- **status:** active
