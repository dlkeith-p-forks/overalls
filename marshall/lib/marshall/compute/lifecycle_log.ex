defmodule Marshall.Compute.LifecycleLog do
  @moduledoc "Committed audit-event notifications are the structured transition log."
  use Ash.Notifier
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;observability] lifecycle-log-projection
  # Only persisted redacted event fields may enter the transition log. Ash must
  # dispatch notifications after the enclosing transaction; rollback emits none.
  # The log line carries the fixed transition identity; full correlation,
  # attribution and outcomes stay in the audited lifecycle event record.
  @impl true
  def notify(%Ash.Notifier.Notification{action: %{name: :record}, data: event}) do
    if event.previous_state do
      Marshall.Events.emit("lifecycle.transition_committed",
        event_id: event.event_id,
        resource_type: resource_atom(event.resource_type),
        resource_id: event.resource_id,
        action: action_atom(event.action),
        previous_state: state_atom(event.previous_state),
        next_state: state_atom(event.next_state)
      )
    else
      Marshall.Events.emit("lifecycle.transition_committed",
        event_id: event.event_id,
        resource_type: resource_atom(event.resource_type),
        resource_id: event.resource_id,
        action: action_atom(event.action),
        next_state: state_atom(event.next_state)
      )
    end

    :ok
  end

  def notify(_), do: :ok

  # Closed resource identity atoms for diagnostic events; bare module short
  # names have no corresponding atom and must never be atomized at runtime.
  defp resource_atom("CleanupRequest"), do: :cleanup_request
  defp resource_atom("BackupSnapshot"), do: :backup_snapshot
  defp resource_atom("CloneRequest"), do: :clone_request
  defp resource_atom("CloneCopy"), do: :clone_copy
  defp resource_atom("Dataset"), do: :dataset
  defp resource_atom("Evacuation"), do: :evacuation
  defp resource_atom("EvacuationItem"), do: :evacuation_item
  defp resource_atom("Host"), do: :host
  defp resource_atom("HostDrain"), do: :host_drain
  defp resource_atom("Import"), do: :import
  defp resource_atom("Operation"), do: :operation
  defp resource_atom("PhysicalOutcome"), do: :physical_outcome
  defp resource_atom("Permit"), do: :permit
  defp resource_atom("Relocation"), do: :relocation
  defp resource_atom("Reservation"), do: :reservation
  defp resource_atom("ResizeRequest"), do: :resize_request
  defp resource_atom("Resize"), do: :resize
  defp resource_atom("SnapshotPointer"), do: :snapshot_pointer
  defp resource_atom("SnapshotSet"), do: :snapshot_set
  defp resource_atom("StandbyDisk"), do: :standby_disk
  defp resource_atom("TransferSlot"), do: :transfer_slot
  defp resource_atom("VirtualMachine"), do: :virtual_machine
  defp resource_atom("Execution"), do: :execution
  defp resource_atom("GuestTrust"), do: :guest_trust
  defp resource_atom("Provisioning"), do: :provisioning
  defp resource_atom("ImageTemplate"), do: :image_template
  defp resource_atom("WorkspaceSource"), do: :workspace_source
  defp resource_atom("Thread"), do: :thread
  defp resource_atom("Artifact"), do: :artifact
  defp resource_atom("ViewTicket"), do: :view_ticket
  defp resource_atom("PublishRequest"), do: :publish_request
  defp resource_atom("Subscription"), do: :subscription
  defp resource_atom(_), do: :unrecognized_resource

  # @cc [owner:ghuntley,label:durability;observability] lifecycle-log-total-projection
  # Notifications MUST never raise for a committed audit row. Host labels come
  # from the closed protocol but may lack atoms in Marshall's own release; a
  # fixed diagnostic fallback preserves the durable row and its acknowledgment.
  # Existing atoms outside the reviewed diagnostic vocabulary MUST use that
  # fallback; atoms installed by unrelated dependencies grant no diagnostic authority.
  defp action_atom("mark_running"), do: :mark_running
  defp action_atom("mark_unknown"), do: :mark_unknown
  defp action_atom("initialize_pending"), do: :initialize_pending
  defp action_atom("mark_pending"), do: :mark_pending
  defp action_atom("mark_delivering"), do: :mark_delivering
  defp action_atom("mark_installed"), do: :mark_installed
  defp action_atom("mark_delivered"), do: :mark_delivered
  defp action_atom("mark_failed"), do: :mark_failed
  defp action_atom("mark_materializing"), do: :mark_materializing
  defp action_atom("mark_launching"), do: :mark_launching
  defp action_atom("mark_awaiting_trust"), do: :mark_awaiting_trust
  defp action_atom("mark_awaiting_ssh"), do: :mark_awaiting_ssh
  defp action_atom("mark_ready"), do: :mark_ready
  defp action_atom("mark_superseded"), do: :mark_superseded
  defp action_atom("initialize_staging"), do: :initialize_staging
  defp action_atom("mark_verifying"), do: :mark_verifying
  defp action_atom("mark_sealing"), do: :mark_sealing
  defp action_atom("mark_quarantined"), do: :mark_quarantined
  defp action_atom("mark_retiring"), do: :mark_retiring
  defp action_atom("mark_deleted"), do: :mark_deleted
  defp action_atom("begin_provisioning"), do: :begin_provisioning
  defp action_atom("bind_agent"), do: :bind_agent
  defp action_atom("requeue"), do: :requeue
  defp action_atom("replace_generation"), do: :replace_generation
  defp action_atom("reopen"), do: :reopen
  defp action_atom("mark_deleting"), do: :mark_deleting
  defp action_atom("mark_archived"), do: :mark_archived
  defp action_atom("request_delete"), do: :request_delete
  defp action_atom("admin_delete"), do: :admin_delete
  defp action_atom("finish_delete"), do: :finish_delete
  defp action_atom(value), do: existing_atom(value, :unrecognized_action)

  defp state_atom("pending"), do: :pending
  defp state_atom("delivering"), do: :delivering
  defp state_atom("installed"), do: :installed
  defp state_atom("delivered"), do: :delivered
  defp state_atom("failed"), do: :failed
  defp state_atom("materializing"), do: :materializing
  defp state_atom("launching"), do: :launching
  defp state_atom("awaiting_trust"), do: :awaiting_trust
  defp state_atom("awaiting_ssh"), do: :awaiting_ssh
  defp state_atom("ready"), do: :ready
  defp state_atom("superseded"), do: :superseded
  defp state_atom("staging"), do: :staging
  defp state_atom("verifying"), do: :verifying
  defp state_atom("sealing"), do: :sealing
  defp state_atom("quarantined"), do: :quarantined
  defp state_atom("retiring"), do: :retiring
  defp state_atom("deleted"), do: :deleted
  defp state_atom("provisioning"), do: :provisioning
  defp state_atom("deleting"), do: :deleting
  defp state_atom("archived"), do: :archived
  defp state_atom("active"), do: :active
  defp state_atom(value), do: existing_atom(value, :unrecognized_state)

  @spec existing_atom(term(), atom()) :: atom()
  defp existing_atom(value, fallback) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if Overalls.Diagnostics.Schema.enum?(atom), do: atom, else: fallback
  rescue
    ArgumentError -> fallback
  end

  defp existing_atom(_, fallback), do: fallback
end
