defmodule Porsche.SSH.CommandMessages do
  @moduledoc "Extraction markers for shared command descriptions."
  use Gettext, backend: Porsche.Gettext

  @message_0 dgettext_noop("help", "Show command help.")
  @message_1 dgettext_noop("help", "Show the authenticated account.")
  @message_2 dgettext_noop("help", "List available images.")
  @message_3 dgettext_noop("help", "List machines you can access.")
  @message_4 dgettext_noop("help", "Inspect a machine by name or UUID.")
  @message_5 dgettext_noop(
               "help",
               "Create a machine. Disk maximum: 500 GiB. --source clones a public GitHub, GitLab, Codeberg or Bitbucket repository in the guest."
             )
  @message_6 dgettext_noop("help", "Queue an independent full-disk copy of a machine.")
  @message_7 dgettext_noop("help", "Move a machine to an automatically selected host.")
  @message_8 dgettext_noop(
               "help",
               "Change a machine's CPU and memory; disk may only grow. A running machine stops and restarts."
             )
  @message_9 dgettext_noop("help", "Retry a failed clone or relocation request.")
  @message_10 dgettext_noop(
                "help",
                "Cancel an unpublished clone or uncommitted relocation request."
              )
  @message_11 dgettext_noop("help", "Start a machine.")
  @message_12 dgettext_noop(
                "help",
                "Stop a machine, retaining its disk and discarding suspended memory."
              )
  @message_13 dgettext_noop(
                "help",
                "Delete a machine and its disk. Refused while its owner has it pinned."
              )
  @message_14 dgettext_noop(
                "help",
                "Pin a machine to the top of your lists. Your owner pin wakes it, prevents automatic suspension, and prevents deletion."
              )
  @message_15 dgettext_noop("help", "Remove your pin from a machine.")
  @message_16 dgettext_noop("help", "List access grants.")
  @message_17 dgettext_noop("help", "Grant viewer, operator or manager access.")
  @message_18 dgettext_noop("help", "Revoke an account's shared access.")
  @message_19 dgettext_noop("help", "List your SSH keys.")
  @message_20 dgettext_noop("help", "Revoke one of your SSH keys.")
  @message_21 dgettext_noop(
                "help",
                "Create or replace a named integration at https://NAME.integration.internal."
              )
  @message_22 dgettext_noop("help", "Remove a named integration.")
  @message_23 dgettext_noop("help", "List your integrations.")
  @message_24 dgettext_noop("help", "Inspect an integration without secrets.")
  @message_25 dgettext_noop("help", "Make an integration available to a machine.")
  @message_26 dgettext_noop("help", "Remove a machine's explicit availability.")
  @message_27 dgettext_noop("help", "Create a team you own.")
  @message_28 dgettext_noop("help", "List your teams and roles.")
  @message_29 dgettext_noop("help", "List a team's members.")
  @message_30 dgettext_noop("help", "Add or change an admin or member.")
  @message_31 dgettext_noop("help", "Remove an account's membership.")
  @message_32 dgettext_noop("help", "Offer team ownership to an admin.")
  @message_33 dgettext_noop("help", "Accept a pending ownership offer.")
  @message_34 dgettext_noop("help", "Decline a pending ownership offer.")
  @message_35 dgettext_noop("help", "Cancel your pending ownership offer.")
  @message_36 dgettext_noop("help", "Inspect a previously accepted request.")
  @message_37 dgettext_noop("help", "Close this interactive channel.")
  @message_38 dgettext_noop("help", "Suspend a machine, preserving its memory and disk.")
  @message_39 dgettext_noop(
                "help",
                "Resume preserved memory, waiting for capacity or relocation."
              )
  @message_40 dgettext_noop("help", "Resume a suspended machine's preserved memory.")

  @spec sources() :: [String.t()]
  def sources,
    do: [
      @message_0,
      @message_1,
      @message_2,
      @message_3,
      @message_4,
      @message_5,
      @message_6,
      @message_7,
      @message_8,
      @message_9,
      @message_10,
      @message_11,
      @message_12,
      @message_13,
      @message_14,
      @message_15,
      @message_16,
      @message_17,
      @message_18,
      @message_19,
      @message_20,
      @message_21,
      @message_22,
      @message_23,
      @message_24,
      @message_25,
      @message_26,
      @message_27,
      @message_28,
      @message_29,
      @message_30,
      @message_31,
      @message_32,
      @message_33,
      @message_34,
      @message_35,
      @message_36,
      @message_37,
      @message_38,
      @message_39,
      @message_40
    ]
end
