defmodule Porsche.SSH.CommandMessages do
  @moduledoc "Extraction markers for shared command descriptions."
  use Gettext, backend: Porsche.Gettext

  @messages [
    gettext_noop("Queue an independent full-disk copy of a machine."),
    gettext_noop("Close this interactive channel."),
    gettext_noop("Show command help."),
    gettext_noop("List available images."),
    gettext_noop("Create or replace a named integration at https://NAME.integration.internal."),
    gettext_noop("Make an integration available to a machine."),
    gettext_noop("Remove a machine's explicit availability."),
    gettext_noop("List your integrations."),
    gettext_noop("Remove a named integration."),
    gettext_noop("Inspect an integration without secrets."),
    gettext_noop("List machines you can access."),
    gettext_noop(
      "Create a machine. Disk maximum: 500 GiB. --source clones a public GitHub, GitLab, Codeberg or Bitbucket repository in the guest."
    ),
    gettext_noop("Suspend a machine, preserving its memory and disk."),
    gettext_noop(
      "Pin a machine to the top of your lists. Your owner pin wakes it, prevents automatic suspension, and prevents deletion."
    ),
    gettext_noop("Move a machine to an automatically selected host."),
    gettext_noop("Cancel an unpublished clone or uncommitted relocation request."),
    gettext_noop("Retry a failed clone or relocation request."),
    gettext_noop("Inspect a previously accepted request."),
    gettext_noop(
      "Change a machine's CPU and memory; disk may only grow. A running machine stops and restarts."
    ),
    gettext_noop("Resume preserved memory, waiting for capacity or relocation."),
    gettext_noop("Delete a machine and its disk. Refused while its owner has it pinned."),
    gettext_noop("Grant viewer, operator or manager access."),
    gettext_noop("Revoke an account's shared access."),
    gettext_noop("List access grants."),
    gettext_noop("Inspect a machine by name or UUID."),
    gettext_noop("List your SSH keys."),
    gettext_noop("Revoke one of your SSH keys."),
    gettext_noop("Start a machine."),
    gettext_noop("Stop a machine, retaining its disk and discarding suspended memory."),
    gettext_noop("Create a team you own."),
    gettext_noop("List your teams and roles."),
    gettext_noop("Add or change an admin or member."),
    gettext_noop("Remove an account's membership."),
    gettext_noop("List a team's members."),
    gettext_noop("Accept a pending ownership offer."),
    gettext_noop("Cancel your pending ownership offer."),
    gettext_noop("Decline a pending ownership offer."),
    gettext_noop("Offer team ownership to an admin."),
    gettext_noop("Resume a suspended machine's preserved memory."),
    gettext_noop("Remove your pin from a machine."),
    gettext_noop("Show the authenticated account.")
  ]
  @spec sources() :: [String.t()]
  def sources, do: @messages
end
