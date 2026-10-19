defmodule MarshallWeb.Admin.AuditLabels do
  @moduledoc "Reviewed human labels for administrator audit identifiers."
  use Gettext, backend: MarshallWeb.Gettext

  # @cc [owner:ghuntley,label:product;verification] localized-audit-identifiers
  # Audit display labels MUST use finite reviewed mappings. Canonical action and
  # state identifiers MUST remain unchanged and visible as code in the audit view.
  # Unknown identifiers MUST NOT be turned into dynamically extracted messages.
  @spec action(atom() | String.t()) :: String.t()
  def action(value) when value in [:passkey_add, "passkey_add"],
    do: dgettext("admin_audit", "Passkey added")

  def action(value) when value in [:passkey_remove, "passkey_remove"],
    do: dgettext("admin_audit", "Passkey removed")

  def action(value) when value in [:mfa_verify, "mfa_verify"],
    do: dgettext("admin_audit", "Multi-factor authentication verified")

  def action(value) when value in [:mfa_reset, "mfa_reset"],
    do: dgettext("admin_audit", "Multi-factor authentication reset")

  def action(value) when value in [:user_invite, "user_invite"],
    do: dgettext("admin_audit", "User invited")

  def action(value) when value in [:user_delete, "user_delete"],
    do: dgettext("admin_audit", "User deleted")

  def action(value) when value in [:bootstrap, "bootstrap"],
    do: dgettext("admin_audit", "Administrator bootstrapped")

  def action(value) when value in [:grant, "grant"],
    do: dgettext("admin_audit", "Administrator access granted")

  def action(value) when value in [:revoke, "revoke"],
    do: dgettext("admin_audit", "Administrator access revoked")

  def action(value) when value in [:sessions_revoke, "sessions_revoke"],
    do: dgettext("admin_audit", "Sessions revoked")

  def action(value) when value in [:vm_grant_revoke, "vm_grant_revoke"],
    do: dgettext("admin_audit", "Machine access revoked")

  def action(value) when value in [:ssh_key_revoke, "ssh_key_revoke"],
    do: dgettext("admin_audit", "SSH key revoked")

  def action(value) when value in [:ssh_session_revoke, "ssh_session_revoke"],
    do: dgettext("admin_audit", "SSH session revoked")

  def action(value) when value in [:evacuation_request, "evacuation_request"],
    do: dgettext("admin_audit", "Evacuation requested")

  def action(value) when value in [:evacuation_control, "evacuation_control"],
    do: dgettext("admin_audit", "Evacuation changed")

  def action(value) when value in [:evacuation_approve, "evacuation_approve"],
    do: dgettext("admin_audit", "Evacuation approved")

  def action(value) when value in [:evacuation_replan, "evacuation_replan"],
    do: dgettext("admin_audit", "Evacuation replanned")

  def action(value) when value in [:host_configure, "host_configure"],
    do: dgettext("admin_audit", "Host configured")

  def action(value) when value in [:fleet_certificate_rotate, "fleet_certificate_rotate"],
    do: dgettext("admin_audit", "Fleet certificate rotation requested")

  def action(value) when value in [:vm_lifecycle, "vm_lifecycle"],
    do: dgettext("admin_audit", "Machine lifecycle requested")

  def action(value) when value in [:vm_relocate, "vm_relocate"],
    do: dgettext("admin_audit", "Machine relocation requested")

  def action(value) when value in [:team_create, "team_create"],
    do: dgettext("admin_audit", "Team created")

  def action(value) when value in [:team_membership_change, "team_membership_change"],
    do: dgettext("admin_audit", "Team membership changed")

  def action(value) when value in [:team_transfer_offer, "team_transfer_offer"],
    do: dgettext("admin_audit", "Team ownership offered")

  def action(value) when value in [:team_transfer_accept, "team_transfer_accept"],
    do: dgettext("admin_audit", "Team ownership accepted")

  def action(value) when value in [:team_transfer_decline, "team_transfer_decline"],
    do: dgettext("admin_audit", "Team ownership declined")

  def action(value) when value in [:team_transfer_cancel, "team_transfer_cancel"],
    do: dgettext("admin_audit", "Team ownership offer cancelled")

  def action(value) when value in [:galileo_configure, "galileo_configure"],
    do: dgettext("admin_audit", "Integration configured")

  def action(value) when value in [:galileo_remove, "galileo_remove"],
    do: dgettext("admin_audit", "Integration removed")

  def action(value) when value in [:galileo_attach, "galileo_attach"],
    do: dgettext("admin_audit", "Integration attached")

  def action(value) when value in [:galileo_detach, "galileo_detach"],
    do: dgettext("admin_audit", "Integration detached")

  def action(value) when value in [:editor_login, "editor_login"],
    do: dgettext("admin_audit", "Editor sign-in")

  def action(value) when value in [:editor_credential, "editor_credential"],
    do: dgettext("admin_audit", "Editor credential")

  def action(value) when value in [:editor_lease, "editor_lease"],
    do: dgettext("admin_audit", "Editor lease")

  def action(value) when value in [:account, "account"],
    do: dgettext("admin_audit", "ACME account")

  def action(value) when value in [:certificate, "certificate"],
    do: dgettext("admin_audit", "Certificate")

  def action(value) when value in [:installation, "installation"],
    do: dgettext("admin_audit", "Installation")

  def action(value) when value in [:installed, "installed"],
    do: dgettext("admin_audit", "Installed")

  def action(value) when value in [:register, "register"],
    do: dgettext("admin_audit", "Registered")

  def action(value) when value in [:enqueue, "enqueue"], do: dgettext("admin_audit", "Queued")

  def action(value) when value in [:save_request, "save_request"],
    do: dgettext("admin_audit", "Request saved")

  def action(value) when value in [:mark_order_attempt, "mark_order_attempt"],
    do: dgettext("admin_audit", "Certificate order attempted")

  def action(value) when value in [:bind_order, "bind_order"],
    do: dgettext("admin_audit", "Certificate order bound")

  def action(value) when value in [:record_proof, "record_proof"],
    do: dgettext("admin_audit", "Certificate proof recorded")

  def action(value) when value in [:refresh_proof, "refresh_proof"],
    do: dgettext("admin_audit", "Certificate proof refreshed")

  def action(value) when value in [:finish_issued, "finish_issued"],
    do: dgettext("admin_audit", "Certificate issued")

  def action(value) when value in [:activate, "activate"],
    do: dgettext("admin_audit", "Activated")

  def action(value) when value in [:retire, "retire"], do: dgettext("admin_audit", "Retired")
  def action(value) when value in [:fail, "fail"], do: dgettext("admin_audit", "Failed")

  def action(value) when value in [:fail_unknown_order, "fail_unknown_order"],
    do: dgettext("admin_audit", "Uncertain certificate order failed")

  def action(value) when value in [:progress, "progress"],
    do: dgettext("admin_audit", "Progress updated")

  def action(value) when value in [:acknowledge, "acknowledge"],
    do: dgettext("admin_audit", "Acknowledged")

  def action(value) when value in [:advance, "advance"], do: dgettext("admin_audit", "Advanced")

  def action(value) when value in [:allocate, "allocate"],
    do: dgettext("admin_audit", "Allocated")

  def action(value) when value in [:apply_resize, "apply_resize"],
    do: dgettext("admin_audit", "Resize applied")

  def action(value) when value in [:approve, "approve"], do: dgettext("admin_audit", "Approved")
  def action(value) when value in [:archive, "archive"], do: dgettext("admin_audit", "Archived")

  def action(value) when value in [:begin_copy, "begin_copy"],
    do: dgettext("admin_audit", "Copy started")

  def action(value) when value in [:begin_import, "begin_import"],
    do: dgettext("admin_audit", "Import started")

  def action(value) when value in [:block, "block"], do: dgettext("admin_audit", "Blocked")
  def action(value) when value in [:cancel, "cancel"], do: dgettext("admin_audit", "Cancelled")

  def action(value) when value in [:cancelled, "cancelled"],
    do: dgettext("admin_audit", "Cancelled")

  def action(value) when value in [:capture, "capture"],
    do: dgettext("admin_audit", "Snapshot capture started")

  def action(value) when value in [:checkpoint, "checkpoint"],
    do: dgettext("admin_audit", "Checkpoint saved")

  def action(value) when value in [:complete, "complete"], do: dgettext("admin_audit", "Complete")

  def action(value) when value in [:complete_cleanup, "complete_cleanup"],
    do: dgettext("admin_audit", "Cleanup completed")

  def action(value) when value in [:confirm, "confirm"], do: dgettext("admin_audit", "Confirmed")

  def action(value) when value in [:confirm_capture, "confirm_capture"],
    do: dgettext("admin_audit", "Snapshot capture confirmed")

  def action(value) when value in [:confirm_copy, "confirm_copy"],
    do: dgettext("admin_audit", "Copy confirmed")

  def action(value) when value in [:confirm_import, "confirm_import"],
    do: dgettext("admin_audit", "Import confirmed")

  def action(value) when value in [:confirm_readiness, "confirm_readiness"],
    do: dgettext("admin_audit", "Readiness confirmed")

  def action(value) when value in [:confirm_ready, "confirm_ready"],
    do: dgettext("admin_audit", "Readiness confirmed")

  def action(value) when value in [:continue, "continue"],
    do: dgettext("admin_audit", "Continued")

  def action(value) when value in [:defer, "defer"], do: dgettext("admin_audit", "Deferred")

  def action(value) when value in [:dispatch, "dispatch"],
    do: dgettext("admin_audit", "Dispatched")

  def action(value) when value in [:dispatch_destination, "dispatch_destination"],
    do: dgettext("admin_audit", "Destination work dispatched")

  def action(value) when value in [:dispatch_key, "dispatch_key"],
    do: dgettext("admin_audit", "Key dispatched")

  def action(value) when value in [:fail_activation, "fail_activation"],
    do: dgettext("admin_audit", "Activation failed")

  def action(value) when value in [:fail_readiness, "fail_readiness"],
    do: dgettext("admin_audit", "Readiness failed")

  def action(value) when value in [:fence, "fence"], do: dgettext("admin_audit", "Fenced")

  def action(value) when value in [:finish_cancellation, "finish_cancellation"],
    do: dgettext("admin_audit", "Cancellation completed")

  def action(value) when value in [:finish_deletion, "finish_deletion"],
    do: dgettext("admin_audit", "Deletion completed")

  def action(value) when value in [:handoff, "handoff"],
    do: dgettext("admin_audit", "Placement switched")

  def action(value) when value in [:idle_policy, "idle_policy"],
    do: dgettext("admin_audit", "Idle policy updated")

  def action(value) when value in [:observe, "observe"],
    do: dgettext("admin_audit", "Machine state observed")

  def action(value) when value in [:observe_activation, "observe_activation"],
    do: dgettext("admin_audit", "Activation observed")

  def action(value) when value in [:offer, "offer"], do: dgettext("admin_audit", "Work offered")

  def action(value) when value in [:offer_destination_cleanup, "offer_destination_cleanup"],
    do: dgettext("admin_audit", "Destination cleanup offered")

  def action(value) when value in [:offer_destination_revocation, "offer_destination_revocation"],
    do: dgettext("admin_audit", "Destination revocation offered")

  def action(value) when value in [:offer_key_retirement, "offer_key_retirement"],
    do: dgettext("admin_audit", "Key retirement offered")

  def action(value) when value in [:offer_source_revocation, "offer_source_revocation"],
    do: dgettext("admin_audit", "Source revocation offered")

  def action(value)
      when value in [:offer_source_snapshot_cleanup, "offer_source_snapshot_cleanup"],
      do: dgettext("admin_audit", "Source snapshot cleanup offered")

  def action(value) when value in [:pause, "pause"], do: dgettext("admin_audit", "Paused")

  def action(value) when value in [:prepare, "prepare"],
    do: dgettext("admin_audit", "Preparation started")

  def action(value) when value in [:prepare_import, "prepare_import"],
    do: dgettext("admin_audit", "Import prepared")

  def action(value) when value in [:publish, "publish"], do: dgettext("admin_audit", "Published")
  def action(value) when value in [:ready, "ready"], do: dgettext("admin_audit", "Ready")

  def action(value) when value in [:reconcile, "reconcile"],
    do: dgettext("admin_audit", "Reconciled")

  def action(value) when value in [:record, "record"], do: dgettext("admin_audit", "Recorded")

  def action(value) when value in [:record_cancellation_start, "record_cancellation_start"],
    do: dgettext("admin_audit", "Cancellation restart recorded")

  def action(value) when value in [:record_cancellation_stop, "record_cancellation_stop"],
    do: dgettext("admin_audit", "Cancellation stop recorded")

  def action(value) when value in [:record_commit, "record_commit"],
    do: dgettext("admin_audit", "Placement switch recorded")

  def action(value) when value in [:record_destination_cleanup, "record_destination_cleanup"],
    do: dgettext("admin_audit", "Destination cleanup recorded")

  def action(value)
      when value in [:record_destination_revocation, "record_destination_revocation"],
      do: dgettext("admin_audit", "Destination revocation recorded")

  def action(value) when value in [:record_import, "record_import"],
    do: dgettext("admin_audit", "Import recorded")

  def action(value) when value in [:record_key, "record_key"],
    do: dgettext("admin_audit", "Key recorded")

  def action(value) when value in [:record_operation, "record_operation"],
    do: dgettext("admin_audit", "Operation recorded")

  def action(value) when value in [:record_progress, "record_progress"],
    do: dgettext("admin_audit", "Progress recorded")

  def action(value) when value in [:record_receive, "record_receive"],
    do: dgettext("admin_audit", "Transfer receipt recorded")

  def action(value) when value in [:record_result, "record_result"],
    do: dgettext("admin_audit", "Result recorded")

  def action(value) when value in [:record_source_restored, "record_source_restored"],
    do: dgettext("admin_audit", "Source restoration recorded")

  def action(value) when value in [:record_source_revocation, "record_source_revocation"],
    do: dgettext("admin_audit", "Source revocation recorded")

  def action(value)
      when value in [:record_source_snapshot_cleanup, "record_source_snapshot_cleanup"],
      do: dgettext("admin_audit", "Source snapshot cleanup recorded")

  def action(value) when value in [:record_stop, "record_stop"],
    do: dgettext("admin_audit", "Stop recorded")

  def action(value) when value in [:record_unconfirmed, "record_unconfirmed"],
    do: dgettext("admin_audit", "Unconfirmed outcome recorded")

  def action(value) when value in [:reflection_metadata, "reflection_metadata"],
    do: dgettext("admin_audit", "Reflection metadata updated")

  def action(value) when value in [:replan, "replan"], do: dgettext("admin_audit", "Replanned")
  def action(value) when value in [:request, "request"], do: dgettext("admin_audit", "Requested")

  def action(value) when value in [:request_cancel, "request_cancel"],
    do: dgettext("admin_audit", "Cancellation requested")

  def action(value) when value in [:request_cancellation, "request_cancellation"],
    do: dgettext("admin_audit", "Cancellation requested")

  def action(value) when value in [:request_delete, "request_delete"],
    do: dgettext("admin_audit", "Deletion requested")

  def action(value) when value in [:request_deletion, "request_deletion"],
    do: dgettext("admin_audit", "Deletion requested")

  def action(value) when value in [:request_key_retirement, "request_key_retirement"],
    do: dgettext("admin_audit", "Key retirement requested")

  def action(value) when value in [:request_pause, "request_pause"],
    do: dgettext("admin_audit", "Pause requested")

  def action(value) when value in [:request_start, "request_start"],
    do: dgettext("admin_audit", "Start requested")

  def action(value) when value in [:request_stop, "request_stop"],
    do: dgettext("admin_audit", "Stop requested")

  def action(value) when value in [:resize, "resize"],
    do: dgettext("admin_audit", "Resize started")

  def action(value) when value in [:resolve, "resolve"], do: dgettext("admin_audit", "Resolved")

  def action(value) when value in [:restart, "restart"],
    do: dgettext("admin_audit", "Restart started")

  def action(value) when value in [:restore_source, "restore_source"],
    do: dgettext("admin_audit", "Source restored")

  def action(value) when value in [:resume, "resume"], do: dgettext("admin_audit", "Resumed")

  def action(value) when value in [:retire_key, "retire_key"],
    do: dgettext("admin_audit", "Key retired")

  def action(value) when value in [:retry, "retry"],
    do: dgettext("admin_audit", "Retry requested")

  def action(value) when value in [:schedule, "schedule"],
    do: dgettext("admin_audit", "Scheduled")

  def action(value) when value in [:stop, "stop"], do: dgettext("admin_audit", "Stop started")

  def action(value) when value in [:stop_source, "stop_source"],
    do: dgettext("admin_audit", "Source stop started")

  def action(value) when value in [:supersede, "supersede"],
    do: dgettext("admin_audit", "Superseded")

  def action(_), do: dgettext("admin_audit", "Unknown")

  @spec state(atom() | String.t() | nil) :: String.t()
  def state(nil), do: "—"
  def state(value) when value in [:created, "created"], do: dgettext("admin_audit", "Created")
  def state(value) when value in [:pending, "pending"], do: dgettext("admin_audit", "Pending")
  def state(value) when value in [:queued, "queued"], do: dgettext("admin_audit", "Queued")

  def state(value) when value in [:preparing, "preparing"],
    do: dgettext("admin_audit", "Preparing")

  def state(value) when value in [:stopping, "stopping"], do: dgettext("admin_audit", "Stopping")

  def state(value) when value in [:capturing, "capturing"],
    do: dgettext("admin_audit", "Capturing")

  def state(value) when value in [:copying, "copying"], do: dgettext("admin_audit", "Copying")

  def state(value) when value in [:publishing, "publishing"],
    do: dgettext("admin_audit", "Publishing")

  def state(value) when value in [:cleaning, "cleaning"],
    do: dgettext("admin_audit", "Cleaning up")

  def state(value) when value in [:complete, "complete"], do: dgettext("admin_audit", "Complete")

  def state(value) when value in [:cancelling, "cancelling"],
    do: dgettext("admin_audit", "Cancelling")

  def state(value) when value in [:cancelled, "cancelled"],
    do: dgettext("admin_audit", "Cancelled")

  def state(value) when value in [:failed, "failed"], do: dgettext("admin_audit", "Failed")
  def state(value) when value in [:offered, "offered"], do: dgettext("admin_audit", "Offered")

  def state(value) when value in [:completed, "completed"],
    do: dgettext("admin_audit", "Complete")

  def state(value) when value in [:approved, "approved"], do: dgettext("admin_audit", "Approved")
  def state(value) when value in [:blocked, "blocked"], do: dgettext("admin_audit", "Blocked")

  def state(value) when value in [:scheduled, "scheduled"],
    do: dgettext("admin_audit", "Scheduled")

  def state(value) when value in [:applied, "applied"], do: dgettext("admin_audit", "Applied")

  def state(value) when value in [:superseded, "superseded"],
    do: dgettext("admin_audit", "Superseded")

  def state(value) when value in [:ready, "ready"], do: dgettext("admin_audit", "Ready")
  def state(value) when value in [:draining, "draining"], do: dgettext("admin_audit", "Draining")
  def state(value) when value in [:drained, "drained"], do: dgettext("admin_audit", "Drained")
  def state(value) when value in [:resumed, "resumed"], do: dgettext("admin_audit", "Resumed")
  def state(value) when value in [:retired, "retired"], do: dgettext("admin_audit", "Retired")

  def state(value) when value in [:acknowledged, "acknowledged"],
    do: dgettext("admin_audit", "Acknowledged")

  def state(value) when value in [:running, "running"], do: dgettext("admin_audit", "Running")
  def state(value) when value in [:stopped, "stopped"], do: dgettext("admin_audit", "Stopped")
  def state(value) when value in [:paused, "paused"], do: dgettext("admin_audit", "Paused")
  def state(value) when value in [:deleted, "deleted"], do: dgettext("admin_audit", "Deleted")
  def state(value) when value in [:unknown, "unknown"], do: dgettext("admin_audit", "Unknown")
  def state(value) when value in [:active, "active"], do: dgettext("admin_audit", "Active")

  def state(value) when value in [:checking_transfer, "checking_transfer"],
    do: dgettext("admin_audit", "Checking transfer")

  def state(value) when value in [:stopping_source, "stopping_source"],
    do: dgettext("admin_audit", "Stopping source")

  def state(value) when value in [:importing, "importing"],
    do: dgettext("admin_audit", "Importing")

  def state(value) when value in [:handoff, "handoff"],
    do: dgettext("admin_audit", "Switching placement")

  def state(value) when value in [:checking_destination, "checking_destination"],
    do: dgettext("admin_audit", "Checking destination")

  def state(value) when value in [:readiness_failed, "readiness_failed"],
    do: dgettext("admin_audit", "Readiness failed")

  def state(value) when value in [:activation_failed, "activation_failed"],
    do: dgettext("admin_audit", "Activation failed")

  def state(value) when value in [:retrying_destination, "retrying_destination"],
    do: dgettext("admin_audit", "Retrying destination")

  def state(value) when value in [:source_cleanup, "source_cleanup"],
    do: dgettext("admin_audit", "Cleaning up source")

  def state(value) when value in [:restoring_source, "restoring_source"],
    do: dgettext("admin_audit", "Restoring source")

  def state(value) when value in [:cancelled_cleanup, "cancelled_cleanup"],
    do: dgettext("admin_audit", "Cleaning up cancellation")

  def state(value) when value in [:deleting_copies, "deleting_copies"],
    do: dgettext("admin_audit", "Deleting copies")

  def state(value) when value in [:resizing, "resizing"], do: dgettext("admin_audit", "Resizing")

  def state(value) when value in [:restarting, "restarting"],
    do: dgettext("admin_audit", "Restarting")

  def state(value) when value in [:fencing, "fencing"], do: dgettext("admin_audit", "Fencing")

  def state(value) when value in [:evacuating, "evacuating"],
    do: dgettext("admin_audit", "Evacuating")

  def state(value) when value in [:resolved, "resolved"], do: dgettext("admin_audit", "Resolved")
  def state(_), do: dgettext("admin_audit", "Unknown")
end
