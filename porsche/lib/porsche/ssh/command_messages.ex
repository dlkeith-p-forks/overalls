defmodule Porsche.SSH.CommandMessages do
  @moduledoc "Extraction markers for shared command descriptions."
  use Gettext, backend: Porsche.Gettext

  @message_0 gettext_noop("Show command help.")
  @message_1 gettext_noop("Show the authenticated account.")
  @message_2 gettext_noop("List available images.")
  @message_3 gettext_noop("List machines you can access.")
  @message_4 gettext_noop("Inspect a machine by name or UUID.")
  @message_5 gettext_noop(
               "Create a machine. Disk maximum: 500 GiB. --source clones a public GitHub, GitLab, Codeberg or Bitbucket repository in the guest."
             )
  @message_6 gettext_noop("Queue an independent full-disk copy of a machine.")
  @message_7 gettext_noop("Move a machine to an automatically selected host.")
  @message_8 gettext_noop(
               "Change a machine's CPU and memory; disk may only grow. A running machine stops and restarts."
             )
  @message_9 gettext_noop("Retry a failed clone or relocation request.")
  @message_10 gettext_noop("Cancel an unpublished clone or uncommitted relocation request.")
  @message_11 gettext_noop("Start a machine.")
  @message_12 gettext_noop("Stop a machine, retaining its disk and discarding suspended memory.")
  @message_13 gettext_noop(
                "Delete a machine and its disk. Refused while its owner has it pinned."
              )
  @message_14 gettext_noop(
                "Pin a machine to the top of your lists. Your owner pin wakes it, prevents automatic suspension, and prevents deletion."
              )
  @message_15 gettext_noop("Remove your pin from a machine.")
  @message_16 gettext_noop("List access grants.")
  @message_17 gettext_noop("Grant viewer, operator or manager access.")
  @message_18 gettext_noop("Revoke an account's shared access.")
  @message_19 gettext_noop("List your SSH keys.")
  @message_20 gettext_noop("Revoke one of your SSH keys.")
  @message_21 gettext_noop(
                "Create or replace a named integration at https://NAME.integration.internal."
              )
  @message_22 gettext_noop("Remove a named integration.")
  @message_23 gettext_noop("List your integrations.")
  @message_24 gettext_noop("Inspect an integration without secrets.")
  @message_25 gettext_noop("Make an integration available to a machine.")
  @message_26 gettext_noop("Remove a machine's explicit availability.")
  @message_27 gettext_noop("Create a team you own.")
  @message_28 gettext_noop("List your teams and roles.")
  @message_29 gettext_noop("List a team's members.")
  @message_30 gettext_noop("Add or change an admin or member.")
  @message_31 gettext_noop("Remove an account's membership.")
  @message_32 gettext_noop("Offer team ownership to an admin.")
  @message_33 gettext_noop("Accept a pending ownership offer.")
  @message_34 gettext_noop("Decline a pending ownership offer.")
  @message_35 gettext_noop("Cancel your pending ownership offer.")
  @message_36 gettext_noop("Inspect a previously accepted request.")
  @message_37 gettext_noop("Close this interactive channel.")
  @message_38 gettext_noop("Suspend a machine, preserving its memory and disk.")
  @message_39 gettext_noop("Resume preserved memory, waiting for capacity or relocation.")
  @message_40 gettext_noop("Resume a suspended machine's preserved memory.")
  @message_41 gettext_noop("List agent threads you can read, with unread counts.")
  @message_42 gettext_noop("Inspect a thread, its pending question and latest plan.")
  @message_43 gettext_noop("List a thread's transcript events after a sequence number.")
  @message_44 gettext_noop("Send a prompt read from standard input to a thread.")
  @message_45 gettext_noop(
                "Answer a thread's pending question with JSON read from standard input."
              )
  @message_46 gettext_noop("Approve a thread's latest plan and start implementing it.")
  @message_47 gettext_noop("Ask for a revised plan, reading the feedback from standard input.")
  @message_48 gettext_noop("Switch a thread between plan and work collaboration.")
  @message_49 gettext_noop("Mark a thread read up to a transcript sequence number.")
  @message_50 gettext_noop("List a machine's terminal sessions you can open.")
  @message_51 gettext_noop("Open your personal terminal session on a machine.")
  @message_52 gettext_noop("Close one of your terminal sessions on a machine.")
  @message_53 gettext_noop("Show a machine's web endpoint, port and visibility.")
  @message_54 gettext_noop(
                "Change a machine's web port or visibility, optionally at an expected revision."
              )
  @message_55 gettext_noop("Stream JSON change notices for machines, threads and this session.")
  @message_56 gettext_noop(
                "Register this device for push notifications. The push key is read from stdin."
              )
  @message_57 gettext_noop("List your push notification devices.")
  @message_58 gettext_noop("Revoke a push notification device.")
  @message_59 gettext_noop("Turn push notifications on or off for one device.")
  @message_terminal_attach gettext_noop(
                             "Attach this SSH terminal to a shared terminal session; needs ssh -t."
                           )

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
      @message_40,
      @message_41,
      @message_42,
      @message_43,
      @message_44,
      @message_45,
      @message_46,
      @message_47,
      @message_48,
      @message_49,
      @message_50,
      @message_51,
      @message_52,
      @message_53,
      @message_54,
      @message_55,
      @message_56,
      @message_57,
      @message_58,
      @message_59,
      @message_terminal_attach
    ]
end
