defmodule Lilly.Clone.Reason do
  @moduledoc "Total mapping from internal clone effect failures to the closed wire reason set."

  @type reason ::
          :authority_unconfirmed
          | :source_unconfirmed
          | :source_authority_unconfirmed
          | :execution_unavailable
          | :storage_busy
          | :snapshot_unconfirmed
          | :copy_unconfirmed
          | :stream_unconfirmed
          | :lease_unconfirmed
          | :receive_unconfirmed
          | :key_unconfirmed
          | :ssh_unconfirmed
          | :permit_unconfirmed
          | :export_revocation_unconfirmed
          | :import_cleanup_unconfirmed
          | :mount_unconfirmed
          | :disk_unconfirmed
          | :effect_unconfirmed

  @contended [:storage_busy, :execution_unavailable]

  # @cc [owner:ghuntley,label:observability;protocol] clone-reason-classification-total
  # Every internal failure atom MUST map to exactly one closed wire reason and
  # the mapping MUST never create atoms from peer or native input. Unknown
  # internal atoms collapse to effect_unconfirmed rather than leaking names.
  @spec classify(term()) :: reason()
  def classify(:clone_authority_unconfirmed), do: :authority_unconfirmed
  def classify(:clone_source_unconfirmed), do: :source_unconfirmed
  def classify(:source_authority_unconfirmed), do: :source_authority_unconfirmed
  def classify(:execution_unavailable), do: :execution_unavailable
  def classify(:unit_state_unavailable), do: :execution_unavailable
  def classify(:storage_busy), do: :storage_busy
  def classify(:host_already_owned), do: :storage_busy
  def classify(:zfs_snapshot_source_unconfirmed), do: :source_unconfirmed
  def classify(:zfs_snapshot_claim_unconfirmed), do: :source_unconfirmed
  def classify(:zfs_ownership_unconfirmed), do: :source_authority_unconfirmed
  def classify(:source_snapshot_unconfirmed), do: :snapshot_unconfirmed
  def classify(:snapshot_unconfirmed), do: :snapshot_unconfirmed
  def classify(:clone_copy_unconfirmed), do: :copy_unconfirmed
  def classify(:clone_stream_unconfirmed), do: :stream_unconfirmed
  def classify(:stream_unconfirmed), do: :stream_unconfirmed
  def classify(:stream_producer_failed), do: :stream_unconfirmed
  def classify(:clone_lease_unconfirmed), do: :lease_unconfirmed
  def classify(:received_dataset_unconfirmed), do: :receive_unconfirmed
  def classify(:receive_unconfirmed), do: :receive_unconfirmed
  def classify(:transfer_key_unconfirmed), do: :key_unconfirmed
  def classify(:invalid_transfer_key_state), do: :key_unconfirmed
  def classify(:invalid_ssh_transfer), do: :ssh_unconfirmed
  def classify(:invalid_transfer_connection), do: :ssh_unconfirmed
  def classify(:ssh_unconfirmed), do: :ssh_unconfirmed
  def classify(:export_permit_unconfirmed), do: :permit_unconfirmed
  def classify(:permit_unconfirmed), do: :permit_unconfirmed
  def classify(:export_revocation_unconfirmed), do: :export_revocation_unconfirmed
  def classify(:import_cleanup_unconfirmed), do: :import_cleanup_unconfirmed
  def classify(:clone_mount_unconfirmed), do: :mount_unconfirmed
  def classify(:disk_unconfirmed), do: :disk_unconfirmed
  def classify(:readiness_unconfirmed), do: :disk_unconfirmed
  def classify(:zfs_dataset_cleanup_unconfirmed), do: :disk_unconfirmed
  def classify(:disk_import_unconfirmed), do: :disk_unconfirmed
  def classify(:disk_not_ready), do: :disk_unconfirmed
  def classify(:vm_claim_unconfirmed), do: :disk_unconfirmed
  def classify(:receive_stream_unconfirmed), do: :receive_unconfirmed
  def classify(:import_state_unconfirmed), do: :import_cleanup_unconfirmed
  def classify(:destination_cleanup_unconfirmed), do: :import_cleanup_unconfirmed
  def classify(:snapshot_state_unconfirmed), do: :snapshot_unconfirmed
  def classify(:snapshot_index_unconfirmed), do: :snapshot_unconfirmed
  def classify(:snapshot_ownership_unconfirmed), do: :snapshot_unconfirmed
  def classify(:source_snapshot_cleanup_unconfirmed), do: :snapshot_unconfirmed
  def classify(:source_snapshots_unconfirmed), do: :snapshot_unconfirmed
  def classify(:clone_copy_state_unconfirmed), do: :copy_unconfirmed
  def classify(:transfer_key_retired), do: :key_unconfirmed
  def classify(:export_endpoint_unconfirmed), do: :permit_unconfirmed
  def classify(:source_unit_unconfirmed), do: :source_authority_unconfirmed
  def classify(:source_tombstone_unconfirmed), do: :source_authority_unconfirmed
  def classify(:invalid_stream), do: :stream_unconfirmed
  def classify(:stream_busy), do: :stream_unconfirmed
  def classify(:stream_timeout), do: :stream_unconfirmed
  def classify(:stream_revoked), do: :stream_unconfirmed
  def classify(:stream_failed), do: :stream_unconfirmed
  def classify(:stream_pipe_failed), do: :stream_unconfirmed
  def classify(:stream_consumer_failed), do: :stream_unconfirmed
  def classify(:stream_children_failed), do: :stream_unconfirmed
  def classify(:stream_helper_unavailable), do: :stream_unconfirmed
  def classify(:stream_diagnostics_limit), do: :stream_unconfirmed
  def classify(_), do: :effect_unconfirmed

  @doc "The internal stage atom reported beside the wire reason; never a peer or native value."
  @spec stage(term()) :: atom()
  def stage(internal) when is_atom(internal) and not is_nil(internal), do: internal
  def stage(_), do: :unknown

  @doc "Contended reasons recur under ordinary load and are logged at the default level."
  @spec contended?(reason()) :: boolean()
  def contended?(reason), do: reason in @contended
end
