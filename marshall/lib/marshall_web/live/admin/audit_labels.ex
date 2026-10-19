defmodule MarshallWeb.Admin.AuditLabels do
  @moduledoc "Reviewed human labels for administrator audit identifiers."
  use Gettext, backend: MarshallWeb.Gettext

  # @cc [owner:ghuntley,label:product;verification] localized-audit-identifiers
  # Audit display labels MUST use finite reviewed mappings. Canonical action and
  # state identifiers MUST remain unchanged and visible as code in the audit view.
  # Unknown identifiers MUST NOT be turned into dynamically extracted messages.
  @spec action(atom() | String.t()) :: String.t()
  def action(value) when value in [:passkey_add, "passkey_add"], do: gettext("Passkey added")

  def action(value) when value in [:passkey_remove, "passkey_remove"],
    do: gettext("Passkey removed")

  def action(value) when value in [:mfa_verify, "mfa_verify"],
    do: gettext("Multi-factor authentication verified")

  def action(value) when value in [:mfa_reset, "mfa_reset"],
    do: gettext("Multi-factor authentication reset")

  def action(value) when value in [:user_invite, "user_invite"], do: gettext("User invited")
  def action(value) when value in [:user_delete, "user_delete"], do: gettext("User deleted")

  def action(value) when value in [:bootstrap, "bootstrap"],
    do: gettext("Administrator bootstrapped")

  def action(value) when value in [:grant, "grant"], do: gettext("Administrator access granted")
  def action(value) when value in [:revoke, "revoke"], do: gettext("Administrator access revoked")

  def action(value) when value in [:sessions_revoke, "sessions_revoke"],
    do: gettext("Sessions revoked")

  def action(value) when value in [:vm_grant_revoke, "vm_grant_revoke"],
    do: gettext("Machine access revoked")

  def action(value) when value in [:ssh_key_revoke, "ssh_key_revoke"],
    do: gettext("SSH key revoked")

  def action(value) when value in [:ssh_session_revoke, "ssh_session_revoke"],
    do: gettext("SSH session revoked")

  def action(value) when value in [:evacuation_request, "evacuation_request"],
    do: gettext("Evacuation requested")

  def action(value) when value in [:evacuation_control, "evacuation_control"],
    do: gettext("Evacuation changed")

  def action(value) when value in [:evacuation_approve, "evacuation_approve"],
    do: gettext("Evacuation approved")

  def action(value) when value in [:evacuation_replan, "evacuation_replan"],
    do: gettext("Evacuation replanned")

  def action(value) when value in [:host_configure, "host_configure"],
    do: gettext("Host configured")

  def action(value) when value in [:fleet_certificate_rotate, "fleet_certificate_rotate"],
    do: gettext("Fleet certificate rotation requested")

  def action(value) when value in [:vm_lifecycle, "vm_lifecycle"],
    do: gettext("Machine lifecycle requested")

  def action(value) when value in [:vm_relocate, "vm_relocate"],
    do: gettext("Machine relocation requested")

  def action(value) when value in [:team_create, "team_create"], do: gettext("Team created")

  def action(value) when value in [:team_membership_change, "team_membership_change"],
    do: gettext("Team membership changed")

  def action(value) when value in [:team_transfer_offer, "team_transfer_offer"],
    do: gettext("Team ownership offered")

  def action(value) when value in [:team_transfer_accept, "team_transfer_accept"],
    do: gettext("Team ownership accepted")

  def action(value) when value in [:team_transfer_decline, "team_transfer_decline"],
    do: gettext("Team ownership declined")

  def action(value) when value in [:team_transfer_cancel, "team_transfer_cancel"],
    do: gettext("Team ownership offer cancelled")

  def action(value) when value in [:galileo_configure, "galileo_configure"],
    do: gettext("Integration configured")

  def action(value) when value in [:galileo_remove, "galileo_remove"],
    do: gettext("Integration removed")

  def action(value) when value in [:galileo_attach, "galileo_attach"],
    do: gettext("Integration attached")

  def action(value) when value in [:galileo_detach, "galileo_detach"],
    do: gettext("Integration detached")

  def action(value) when value in [:editor_login, "editor_login"], do: gettext("Editor sign-in")

  def action(value) when value in [:editor_credential, "editor_credential"],
    do: gettext("Editor credential")

  def action(value) when value in [:editor_lease, "editor_lease"], do: gettext("Editor lease")
  def action(value) when value in [:account, "account"], do: gettext("ACME account")
  def action(value) when value in [:certificate, "certificate"], do: gettext("Certificate")
  def action(value) when value in [:installation, "installation"], do: gettext("Installation")
  def action(value) when value in [:installed, "installed"], do: gettext("Installed")
  def action(value) when value in [:register, "register"], do: gettext("Registered")
  def action(value) when value in [:enqueue, "enqueue"], do: gettext("Queued")
  def action(value) when value in [:save_request, "save_request"], do: gettext("Request saved")

  def action(value) when value in [:mark_order_attempt, "mark_order_attempt"],
    do: gettext("Certificate order attempted")

  def action(value) when value in [:bind_order, "bind_order"],
    do: gettext("Certificate order bound")

  def action(value) when value in [:record_proof, "record_proof"],
    do: gettext("Certificate proof recorded")

  def action(value) when value in [:refresh_proof, "refresh_proof"],
    do: gettext("Certificate proof refreshed")

  def action(value) when value in [:finish_issued, "finish_issued"],
    do: gettext("Certificate issued")

  def action(value) when value in [:activate, "activate"], do: gettext("Activated")
  def action(value) when value in [:retire, "retire"], do: gettext("Retired")
  def action(value) when value in [:fail, "fail"], do: gettext("Failed")

  def action(value) when value in [:fail_unknown_order, "fail_unknown_order"],
    do: gettext("Uncertain certificate order failed")

  def action(value) when value in [:progress, "progress"], do: gettext("Progress updated")
  def action(value) when value in [:acknowledge, "acknowledge"], do: gettext("Acknowledged")
  def action(value) when value in [:advance, "advance"], do: gettext("Advanced")
  def action(value) when value in [:allocate, "allocate"], do: gettext("Allocated")
  def action(value) when value in [:apply_resize, "apply_resize"], do: gettext("Resize applied")
  def action(value) when value in [:approve, "approve"], do: gettext("Approved")
  def action(value) when value in [:archive, "archive"], do: gettext("Archived")
  def action(value) when value in [:begin_copy, "begin_copy"], do: gettext("Copy started")
  def action(value) when value in [:begin_import, "begin_import"], do: gettext("Import started")
  def action(value) when value in [:block, "block"], do: gettext("Blocked")
  def action(value) when value in [:cancel, "cancel"], do: gettext("Cancelled")
  def action(value) when value in [:cancelled, "cancelled"], do: gettext("Cancelled")
  def action(value) when value in [:capture, "capture"], do: gettext("Snapshot capture started")
  def action(value) when value in [:checkpoint, "checkpoint"], do: gettext("Checkpoint saved")
  def action(value) when value in [:complete, "complete"], do: gettext("Complete")

  def action(value) when value in [:complete_cleanup, "complete_cleanup"],
    do: gettext("Cleanup completed")

  def action(value) when value in [:confirm, "confirm"], do: gettext("Confirmed")

  def action(value) when value in [:confirm_capture, "confirm_capture"],
    do: gettext("Snapshot capture confirmed")

  def action(value) when value in [:confirm_copy, "confirm_copy"], do: gettext("Copy confirmed")

  def action(value) when value in [:confirm_import, "confirm_import"],
    do: gettext("Import confirmed")

  def action(value) when value in [:confirm_readiness, "confirm_readiness"],
    do: gettext("Readiness confirmed")

  def action(value) when value in [:confirm_ready, "confirm_ready"],
    do: gettext("Readiness confirmed")

  def action(value) when value in [:continue, "continue"], do: gettext("Continued")
  def action(value) when value in [:defer, "defer"], do: gettext("Deferred")
  def action(value) when value in [:dispatch, "dispatch"], do: gettext("Dispatched")

  def action(value) when value in [:dispatch_destination, "dispatch_destination"],
    do: gettext("Destination work dispatched")

  def action(value) when value in [:dispatch_key, "dispatch_key"], do: gettext("Key dispatched")

  def action(value) when value in [:fail_activation, "fail_activation"],
    do: gettext("Activation failed")

  def action(value) when value in [:fail_readiness, "fail_readiness"],
    do: gettext("Readiness failed")

  def action(value) when value in [:fence, "fence"], do: gettext("Fenced")

  def action(value) when value in [:finish_cancellation, "finish_cancellation"],
    do: gettext("Cancellation completed")

  def action(value) when value in [:finish_deletion, "finish_deletion"],
    do: gettext("Deletion completed")

  def action(value) when value in [:handoff, "handoff"], do: gettext("Placement switched")

  def action(value) when value in [:idle_policy, "idle_policy"],
    do: gettext("Idle policy updated")

  def action(value) when value in [:observe, "observe"], do: gettext("Machine state observed")

  def action(value) when value in [:observe_activation, "observe_activation"],
    do: gettext("Activation observed")

  def action(value) when value in [:offer, "offer"], do: gettext("Work offered")

  def action(value) when value in [:offer_destination_cleanup, "offer_destination_cleanup"],
    do: gettext("Destination cleanup offered")

  def action(value) when value in [:offer_destination_revocation, "offer_destination_revocation"],
    do: gettext("Destination revocation offered")

  def action(value) when value in [:offer_key_retirement, "offer_key_retirement"],
    do: gettext("Key retirement offered")

  def action(value) when value in [:offer_source_revocation, "offer_source_revocation"],
    do: gettext("Source revocation offered")

  def action(value)
      when value in [:offer_source_snapshot_cleanup, "offer_source_snapshot_cleanup"],
      do: gettext("Source snapshot cleanup offered")

  def action(value) when value in [:pause, "pause"], do: gettext("Paused")
  def action(value) when value in [:prepare, "prepare"], do: gettext("Preparation started")

  def action(value) when value in [:prepare_import, "prepare_import"],
    do: gettext("Import prepared")

  def action(value) when value in [:publish, "publish"], do: gettext("Published")
  def action(value) when value in [:ready, "ready"], do: gettext("Ready")
  def action(value) when value in [:reconcile, "reconcile"], do: gettext("Reconciled")
  def action(value) when value in [:record, "record"], do: gettext("Recorded")

  def action(value) when value in [:record_cancellation_start, "record_cancellation_start"],
    do: gettext("Cancellation restart recorded")

  def action(value) when value in [:record_cancellation_stop, "record_cancellation_stop"],
    do: gettext("Cancellation stop recorded")

  def action(value) when value in [:record_commit, "record_commit"],
    do: gettext("Placement switch recorded")

  def action(value) when value in [:record_destination_cleanup, "record_destination_cleanup"],
    do: gettext("Destination cleanup recorded")

  def action(value)
      when value in [:record_destination_revocation, "record_destination_revocation"],
      do: gettext("Destination revocation recorded")

  def action(value) when value in [:record_import, "record_import"],
    do: gettext("Import recorded")

  def action(value) when value in [:record_key, "record_key"], do: gettext("Key recorded")

  def action(value) when value in [:record_operation, "record_operation"],
    do: gettext("Operation recorded")

  def action(value) when value in [:record_progress, "record_progress"],
    do: gettext("Progress recorded")

  def action(value) when value in [:record_receive, "record_receive"],
    do: gettext("Transfer receipt recorded")

  def action(value) when value in [:record_result, "record_result"],
    do: gettext("Result recorded")

  def action(value) when value in [:record_source_restored, "record_source_restored"],
    do: gettext("Source restoration recorded")

  def action(value) when value in [:record_source_revocation, "record_source_revocation"],
    do: gettext("Source revocation recorded")

  def action(value)
      when value in [:record_source_snapshot_cleanup, "record_source_snapshot_cleanup"],
      do: gettext("Source snapshot cleanup recorded")

  def action(value) when value in [:record_stop, "record_stop"], do: gettext("Stop recorded")

  def action(value) when value in [:record_unconfirmed, "record_unconfirmed"],
    do: gettext("Unconfirmed outcome recorded")

  def action(value) when value in [:reflection_metadata, "reflection_metadata"],
    do: gettext("Reflection metadata updated")

  def action(value) when value in [:replan, "replan"], do: gettext("Replanned")
  def action(value) when value in [:request, "request"], do: gettext("Requested")

  def action(value) when value in [:request_cancel, "request_cancel"],
    do: gettext("Cancellation requested")

  def action(value) when value in [:request_cancellation, "request_cancellation"],
    do: gettext("Cancellation requested")

  def action(value) when value in [:request_delete, "request_delete"],
    do: gettext("Deletion requested")

  def action(value) when value in [:request_deletion, "request_deletion"],
    do: gettext("Deletion requested")

  def action(value) when value in [:request_key_retirement, "request_key_retirement"],
    do: gettext("Key retirement requested")

  def action(value) when value in [:request_pause, "request_pause"],
    do: gettext("Pause requested")

  def action(value) when value in [:request_start, "request_start"],
    do: gettext("Start requested")

  def action(value) when value in [:request_stop, "request_stop"], do: gettext("Stop requested")
  def action(value) when value in [:resize, "resize"], do: gettext("Resize started")
  def action(value) when value in [:resolve, "resolve"], do: gettext("Resolved")
  def action(value) when value in [:restart, "restart"], do: gettext("Restart started")

  def action(value) when value in [:restore_source, "restore_source"],
    do: gettext("Source restored")

  def action(value) when value in [:resume, "resume"], do: gettext("Resumed")
  def action(value) when value in [:retire_key, "retire_key"], do: gettext("Key retired")
  def action(value) when value in [:retry, "retry"], do: gettext("Retry requested")
  def action(value) when value in [:schedule, "schedule"], do: gettext("Scheduled")
  def action(value) when value in [:stop, "stop"], do: gettext("Stop started")

  def action(value) when value in [:stop_source, "stop_source"],
    do: gettext("Source stop started")

  def action(value) when value in [:supersede, "supersede"], do: gettext("Superseded")
  def action(_), do: gettext("Unknown")

  @spec state(atom() | String.t() | nil) :: String.t()
  def state(nil), do: "—"
  def state(value) when value in [:created, "created"], do: gettext("Created")
  def state(value) when value in [:pending, "pending"], do: gettext("Pending")
  def state(value) when value in [:queued, "queued"], do: gettext("Queued")
  def state(value) when value in [:preparing, "preparing"], do: gettext("Preparing")
  def state(value) when value in [:stopping, "stopping"], do: gettext("Stopping")
  def state(value) when value in [:capturing, "capturing"], do: gettext("Capturing")
  def state(value) when value in [:copying, "copying"], do: gettext("Copying")
  def state(value) when value in [:publishing, "publishing"], do: gettext("Publishing")
  def state(value) when value in [:cleaning, "cleaning"], do: gettext("Cleaning up")
  def state(value) when value in [:complete, "complete"], do: gettext("Complete")
  def state(value) when value in [:cancelling, "cancelling"], do: gettext("Cancelling")
  def state(value) when value in [:cancelled, "cancelled"], do: gettext("Cancelled")
  def state(value) when value in [:failed, "failed"], do: gettext("Failed")
  def state(value) when value in [:offered, "offered"], do: gettext("Offered")
  def state(value) when value in [:completed, "completed"], do: gettext("Complete")
  def state(value) when value in [:approved, "approved"], do: gettext("Approved")
  def state(value) when value in [:blocked, "blocked"], do: gettext("Blocked")
  def state(value) when value in [:scheduled, "scheduled"], do: gettext("Scheduled")
  def state(value) when value in [:applied, "applied"], do: gettext("Applied")
  def state(value) when value in [:superseded, "superseded"], do: gettext("Superseded")
  def state(value) when value in [:ready, "ready"], do: gettext("Ready")
  def state(value) when value in [:draining, "draining"], do: gettext("Draining")
  def state(value) when value in [:drained, "drained"], do: gettext("Drained")
  def state(value) when value in [:resumed, "resumed"], do: gettext("Resumed")
  def state(value) when value in [:retired, "retired"], do: gettext("Retired")
  def state(value) when value in [:acknowledged, "acknowledged"], do: gettext("Acknowledged")
  def state(value) when value in [:running, "running"], do: gettext("Running")
  def state(value) when value in [:stopped, "stopped"], do: gettext("Stopped")
  def state(value) when value in [:paused, "paused"], do: gettext("Paused")
  def state(value) when value in [:deleted, "deleted"], do: gettext("Deleted")
  def state(value) when value in [:unknown, "unknown"], do: gettext("Unknown")
  def state(value) when value in [:active, "active"], do: gettext("Active")

  def state(value) when value in [:checking_transfer, "checking_transfer"],
    do: gettext("Checking transfer")

  def state(value) when value in [:stopping_source, "stopping_source"],
    do: gettext("Stopping source")

  def state(value) when value in [:importing, "importing"], do: gettext("Importing")
  def state(value) when value in [:handoff, "handoff"], do: gettext("Switching placement")

  def state(value) when value in [:checking_destination, "checking_destination"],
    do: gettext("Checking destination")

  def state(value) when value in [:readiness_failed, "readiness_failed"],
    do: gettext("Readiness failed")

  def state(value) when value in [:activation_failed, "activation_failed"],
    do: gettext("Activation failed")

  def state(value) when value in [:retrying_destination, "retrying_destination"],
    do: gettext("Retrying destination")

  def state(value) when value in [:source_cleanup, "source_cleanup"],
    do: gettext("Cleaning up source")

  def state(value) when value in [:restoring_source, "restoring_source"],
    do: gettext("Restoring source")

  def state(value) when value in [:cancelled_cleanup, "cancelled_cleanup"],
    do: gettext("Cleaning up cancellation")

  def state(value) when value in [:deleting_copies, "deleting_copies"],
    do: gettext("Deleting copies")

  def state(value) when value in [:resizing, "resizing"], do: gettext("Resizing")
  def state(value) when value in [:restarting, "restarting"], do: gettext("Restarting")
  def state(value) when value in [:fencing, "fencing"], do: gettext("Fencing")
  def state(value) when value in [:evacuating, "evacuating"], do: gettext("Evacuating")
  def state(value) when value in [:resolved, "resolved"], do: gettext("Resolved")
  def state(_), do: gettext("Unknown")
end
