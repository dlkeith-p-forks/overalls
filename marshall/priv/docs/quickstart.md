# Getting started

Use Porsche to manage machines over SSH, with the same account and permissions
as Marshall’s web interface.

## Register your key

Sign in to Marshall using your email login and open
[SSH keys](/settings/ssh-keys). Paste one OpenSSH public key and optionally give it
a label. Paste the `.pub` file, never the private key. Supported public keys are
Ed25519, ECDSA and RSA (at least 2048 bits). Certificates and `authorized_keys`
options are not accepted.

The page shows each key's label, type, fingerprint and creation time. Remove a key
to revoke its access. You may remove your last SSH key and continue using email
login. Adding the same public key again creates a new registration; previous
sessions remain revoked.

Guest SSH and browser terminals use an automatically allocated Linux login such
as `u200001`, with `/home/u200001` as its home. The login comes from a durable
account UID rather than your email address. It stays the same across machines and
same-account email changes. A new account registered after retirement receives a
different identity and does not inherit the former account's home or access.
Marshall continues showing your email address; there is no username setting.

## Connect

Use the Porsche hostname supplied by your operator. In a local terminal, run
`ssh YOUR_PORSCHE_HOST help` for one command, or `ssh YOUR_PORSCHE_HOST` for an
interactive prompt. Verify the server host-key fingerprint using your operator's
trusted instructions. Management uses port 22.

For browser approval of an unknown key, start an interactive connection with
`ssh YOUR_PORSCHE_HOST` and keep it open. Porsche gives you a short-lived approval
link after proving possession of the private key. Open it in your browser, sign
in, compare the fingerprint and explicitly approve. Opening the link alone does
not register a key. Links expire after ten minutes and stop working when their
SSH connection closes. The interactive prompt can continue after approval.

For one-shot exec commands, register the key on Marshall's SSH keys page first,
or complete approval in an interactive connection before retrying the command.

## Install the Overalls CLI

Each machine's page has a "Connect from your computer" section with a one-line
installer that sets up SSH and connects to that machine:

- Linux and macOS: the `curl … /bin/install.sh | bash` command.
- Windows: open "Windows (PowerShell)" and run its `powershell …` command in
  PowerShell. Windows needs OpenSSH 9.6 or newer; the installer offers to
  install it with winget when the built-in client is older. Afterwards connect
  with `overalls ssh HOST`.

## First commands

At the Porsche prompt, enter:

```porsche
whoami
images
ls
new --name example-machine
show example-machine
stop example-machine
start example-machine
relocate example-machine
```

With exec, place the same command after `ssh YOUR_PORSCHE_HOST` and quote it for
your local shell when needed. Porsche does not evaluate shell expressions,
pipelines or substitutions. Single and double quotes group command arguments.

Machine references accept names or UUIDs. Names are lowercase, begin with a letter,
and contain letters, digits and single separating hyphens, up to 63 characters.
UUID-shaped names are reserved for machine identifiers.
Creation without a name generates one. Creation without an image selects the
operator's default image. Creation without `--profile` selects OSS; use
`--profile customer` for the restricted Customer environment. Omitted CPU,
memory and disk requests use defaults raised to the image minimum; explicitly
undersized requests fail.

Stop retains the disk. `rm MACHINE` deletes the machine and its disk. A name is
available for reuse only after cleanup is confirmed. Use `exit` to leave the prompt.

`relocate MACHINE` moves the same machine and disk to another eligible physical
host. Porsche never accepts a destination: Marshall selects one from current
capacity, image availability and transfer readiness. The machine keeps its name,
identity, sharing and private address.

VM disks have a maximum capacity of **500 GiB** (536,870,912,000 bytes).
Creation and resize requests above this limit are rejected, including Porsche
`new --disk` requests.
