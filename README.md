# Overalls

**An AI-first developer platform that you own.**

> **Research preview.** Overalls launches on 3 November 2026.
> [Get notified](https://overalls.dev/#newsletter).

Overalls is a self-hosted platform for development machines and the AI agents
that work on them. Every machine is a persistent Firecracker microVM running
NixOS, Ubuntu or Windows, and it keeps its disk, name and address when you
stop, start, resize, clone or move it.

Overalls has its own agent built in: start a thread on any machine from the
browser or the CLI, and it keeps working after you close your laptop, waking
the machine if it was stopped. Claude Code and Codex come pre-installed too,
with no API keys on the machine and every token accounted for.

Open any repository, branch or pull request in a fresh machine with one click,
share it with your coworkers, and work from the browser, SSH, VS Code or the
`overalls` CLI. Put hosts in every region your team works in.

There is no hosted version to sign up for: you install it and run it yourself.

- Website: <https://overalls.dev>
- Self-hosting guide: <https://overalls.dev/self-host/>
- Architecture: <https://overalls.dev/architecture.html>

## What you get

Status labels: **STABLE** built and covered by acceptance tests ·
**PREVIEW** works, with rough edges · **EXPERIMENTAL** still being built.

### Machines

| Feature | Status | |
| --- | --- | --- |
| Persistent microVMs | STABLE | Each machine is a Firecracker guest with its own kernel and a ZFS disk of up to 500 GiB. Stopping it keeps the disk. |
| Clone, resize, relocate | STABLE | Clone into an independent copy, resize CPU and memory, grow the disk, or move a stopped machine to another host while keeping its name, identity and address. |
| Tools already installed | STABLE | Linux guests ship with Podman, git, the GitHub CLI, tmux, Neovim, ripgrep, jq, direnv and devenv. |
| Caching HTTP proxy | STABLE | Package downloads (apt, Nix, pip, npm and the like) go through Brady, which fetches only from verified upstreams and caches public, anonymous responses. |
| Locked-down profile | STABLE | For customer material: no outbound network, no sharing, no web exposure, and SSH for the owner only. |

### Operating systems

| Guest | Status |
| --- | --- |
| NixOS (default) | STABLE |
| Ubuntu 26.04 LTS | STABLE |
| Windows Server 2025 | STABLE |
| AlmaLinux | EXPERIMENTAL |
| FreeBSD | EXPERIMENTAL |
| illumos | EXPERIMENTAL |

### Working on a machine

| Feature | Status | |
| --- | --- | --- |
| Browser terminal | STABLE | Many persistent terminals per machine. People you share with start in watch mode and can take control. |
| Clients for macOS, Linux and Windows | STABLE | A one-line installer sets up SSH to every machine. |
| SSH management | STABLE | `ssh <gateway> new`, `ls`, `start`, `stop`, `rm`, with `--json` and retry-safe request IDs. |
| Public web apps | STABLE | Each machine can serve HTTPS on its own subdomain under `apps.<your-domain>`. |
| Browser editor | PREVIEW | Built from Microsoft's official Code OSS source, with Open VSX extensions. |

### Collaboration and repositories

| Feature | Status | |
| --- | --- | --- |
| Share with coworkers | STABLE | Viewer, operator and manager roles. Cedar checks every action when it runs, so revoking access takes effect immediately. |
| Teams | STABLE | Owners, admins and members share a pool of machines, integrations and secrets. |
| Repo launch links | STABLE | `https://<your-domain>/#https://github.com/OWNER/REPO` creates a machine with that repo cloned. Add `/tree/BRANCH`, `/commit/SHA` or `/pull/N`. |
| Browser extension | STABLE | Open the GitHub, GitLab, Codeberg or Bitbucket Cloud page you're on in a new machine. |

### AI

| Feature | Status | |
| --- | --- | --- |
| Claude Code and Codex | STABLE | Pre-installed and already pointed at Ziggy, with no credentials on the machine. |
| Inference without keys | STABLE | Guests call `https://llm.internal`; Ziggy adds provider credentials outside the guest. |
| AI usage accounting | STABLE | Usage per user, machine and agent thread, with fleet-wide reports for administrators. Unmeasured usage shows as unknown, never as zero. |
| Integrations without keys | STABLE | `<name>.integration.internal` endpoints; Galileo adds credentials at the edge. |
| Agent threads | STABLE | The built-in agent wakes stopped machines and keeps working after you close your laptop. |

### Running the platform

| Feature | Status | |
| --- | --- | --- |
| Hosts near your developers | STABLE | Keep the control plane in one region and put hosts wherever your team works. |
| Multi-host fleet and HA | STABLE | Multiple Marshall instances behind HAProxy against a shared PostgreSQL. |
| Node maintenance | STABLE | Evacuate or drain a host without losing anyone's work. |
| Off-site backups | STABLE | Restic to any S3-compatible bucket, with checks that prove backups restore. |
| Inception | EXPERIMENTAL | A guest that runs a whole Overalls stack inside itself. |

## A taste

Every management command works in the browser, at an interactive SSH prompt or
as a one-off `ssh` command. Add `--json` when a script (or agent) is reading
the output.

```console
$ ssh <gateway> new --name scratch
$ ssh <gateway> ls
$ ssh <gateway> resize scratch --cpu 4 --memory 8192
$ ssh <gateway> clone scratch --name scratch-copy --request-id copy-1 --no-wait
$ ssh <gateway> share add scratch colleague@example.com operator
$ overalls open https://github.com/OWNER/REPO
```

`<gateway>` is your own deployment's domain.

## Architecture

Marshall holds the record of what should exist. Lilly hosts make it physically
true and report back. The other services sit at the edges.

| Component | Role |
| --- | --- |
| **Marshall** | Web app and control plane (Elixir, Phoenix, Ash, PostgreSQL) |
| **Lilly** | Host provisioner: runs Firecracker guests on ZFS behind isolated networks |
| **Porsche** | SSH management gateway |
| **Audi** | Authoritative DNS, guest SSH and public HTTPS for web apps |
| **Brady** | Egress proxy and cache |
| **Enrico** | Private GitHub mirror |
| **Galileo** | Integration gateway that adds credentials at the edge |
| **Ziggy** | Inference proxy for OpenAI and Anthropic models |
| **Lyra** | The `overalls` CLI and guest tools (Rust) |

Each host's Lilly dials out to Marshall over HTTPS with its own revocable
credential. Each guest gets an isolated network, and traffic between guests is
blocked. Credentials are added at the edge, never handed to the guest.

See the [architecture page](https://overalls.dev/architecture.html) for
details.

## Run it yourself

Overalls is a set of NixOS modules plus tools for installing and enrolling
bare-metal hosts. Your fleet is defined in a Git repository: you fork Overalls,
declare your hosts, and each host keeps itself up to date from your branch.
You can start with one server and add hosts later.

| Requirement | |
| --- | --- |
| Hardware | x86_64 bare metal with a working `/dev/kvm` (Hetzner dedicated and EC2 bare metal are supported by the bootstrap tool) |
| Operating system | NixOS 26.05, installed for you from a rescue or Ubuntu system |
| Storage | ZFS, which holds the guest disks |
| Services | PostgreSQL with TLS, and an authenticated SMTP relay for sign-in links |
| Network | A domain you control, with `apps.<your-domain>` delegated to Audi. Certificates come from ACME. |
| Your laptop | Nix with flakes, and a Git server your hosts can read from |

Follow the [self-hosting guide](https://overalls.dev/self-host/) to go from a
bare-metal server to your first machine.

## Security

Please report vulnerabilities through a
[private security advisory](https://github.com/ghuntley/overalls/security/advisories/new),
not a public issue. See [SECURITY.md](SECURITY.md) for the full policy.

## Who is behind Overalls

Overalls is built by
[Geoffrey Huntley](https://ghuntley.com/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls),
with support from
[Antithesis](https://antithesis.com/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls),
[Cachix](https://www.cachix.org/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls)
and
[Namespace Labs](https://namespace.so/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls).

## Licence

Overalls is open source under the [MIT licence](LICENSE).
