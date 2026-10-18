# Overalls documentation

Use Overalls from your browser or manage machines over SSH with Porsche. Marshall
provides the web interface and account permissions. Use the same account in both.

The browser extension opens supported repository pages in Overalls. The SSH guides
describe Porsche v1; your operator supplies the SSH hostname for deployments
with Porsche enabled.

- [Browser extension](/docs/browser-extension.md): open supported repositories in Overalls.
- [Getting started](/docs/quickstart.md): register a key and connect.
- [Command reference](/docs/commands.md): syntax and available options.
- [Automation](/docs/automation.md): JSON, retries and completion.
- [Reflection integration](/docs/reflection.md): discover guest metadata and available private integrations.

These pages are public and contain no account or fleet data. Each page is available
as HTML by removing `.md` from its URL. Language-model clients can start at
[/llms.txt](/llms.txt) and follow the Markdown links.

Porsche manages machines; it does not provide a guest shell, guest file transfer,
port forwarding or an SSH agent forwarding service. Machine console access is
available separately in Marshall's web interface, subject to account permissions.
