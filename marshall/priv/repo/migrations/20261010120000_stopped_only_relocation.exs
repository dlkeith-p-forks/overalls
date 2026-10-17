defmodule Marshall.Repo.Migrations.StoppedOnlyRelocation do
  @moduledoc "ADR-0155: one stopped full copy is the only relocation; drop strategy and stream kinds."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:recovery;protocol] stopped-only-cut-keeps-history-readable
  # The cut MUST drop the relocation strategy and source request kind columns
  # rather than rewrite finished rows to a strategy they did not use. PostgreSQL
  # MUST check the probe-before-stop constraint for every relocation row.
  @spec up() :: :ok
  def up do
    drop_if_exists constraint(:compute_relocations, :relocation_full_stop_requires_probe)
    drop_if_exists constraint(:compute_relocations, :relocation_transfer_strategy)

    alter table(:compute_relocations) do
      remove :strategy
    end

    create constraint(:compute_relocations, :relocation_stop_requires_probe,
             check: """
             (source_preflight_request_id IS NULL OR source_stop_operation_id IS NOT NULL) AND (original_state <> 'running' OR source_stop_operation_id IS NULL OR source_preflight_request_id IS NOT NULL)
             """
           )

    drop_if_exists constraint(:compute_source_permit_requests, :final_import_has_receipt)

    alter table(:compute_source_permit_requests) do
      remove :kind
    end

    create constraint(:compute_source_permit_requests, :final_import_has_receipt,
             check: """
             (import_requested_at IS NULL AND destination_imported_at IS NULL) OR (import_requested_at IS NOT NULL AND destination_dataset_guid IS NOT NULL)
             """
           )

    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("The stopped-only relocation cut requires a forward migration")
end
