defmodule Marshall.Compute.ExpireLifecycleEvents do
  @moduledoc "Bounded lifecycle audit retention; never deletes execution evidence."
  use Ash.Resource.Actions.Implementation

  require Marshall.Events

  # @cc [owner:ghuntley,label:durability;security] paper-trail-retention-inventory
  # The allowlist MUST contain every current PaperTrail version table, and only
  # tables every installation has. A removed resource's version table leaves the
  # allowlist one push before the migration that drops it, so the release serving
  # during that migration never queries a dropped table. Expiry remains globally
  # bounded to 1000 rows.
  @version_tables ~w(
    access_grants_versions
    account_guest_accounts_versions
    agent_roots_versions
    agent_threads_versions
    compute_clone_requests_versions
    compute_evacuation_items_versions
    compute_evacuations_versions
    compute_host_credentials_versions
    compute_host_drains_versions
    compute_images_versions
    compute_virtual_machines_versions
    editor_credentials_versions
    editor_leases_versions
    editor_logins_versions
    galileo_attachments_versions
    galileo_credentials_versions
    galileo_integrations_versions
    inference_credentials_versions
    inference_requests_versions
    ingress_endpoints_versions
    ingress_editor_assets_receipts_versions
    ingress_fleet_certificate_accounts_versions
    ingress_fleet_certificate_installations_versions
    ingress_fleet_certificates_versions
    ingress_environment_streams_versions
    ingress_environments_versions
    ingress_routes_versions
    ingress_services_versions
    ingress_sessions_versions
    ingress_web_credentials_versions
    ingress_web_logins_versions
    ingress_web_streams_versions
    ssh_keys_versions
    team_members_versions
    team_transfers_versions
    teams_versions
    terminal_grants_versions
    terminal_sessions_versions
    thread_grants_versions
    threads_versions
  )

  @doc false
  @spec version_tables() :: [String.t()]
  def version_tables, do: @version_tables

  # @cc [owner:ghuntley,label:capacity;durability] lifecycle-retention-bounded
  # Each transaction MUST remove at most 1000 expired lifecycle/PaperTrail events. A full
  # batch schedules continuation atomically. Operational receipts and tombstones
  # MUST remain independent of audit expiry.
  @impl true
  def run(_, _, _) do
    result =
      Marshall.Repo.transaction(fn ->
        %{num_rows: count} =
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            """
            WITH expired AS (
              SELECT id FROM compute_lifecycle_events
              WHERE expires_at <= clock_timestamp()
              ORDER BY expires_at, id LIMIT 1000 FOR UPDATE SKIP LOCKED
            ) DELETE FROM compute_lifecycle_events e USING expired x WHERE e.id = x.id
            """,
            [],
            log: false
          )

        count =
          Enum.reduce_while(@version_tables, count, fn table, total ->
            if total == 1000 do
              {:halt, total}
            else
              expire_version_table(table, total)
            end
          end)

        if count == 1000 do
          AshOban.schedule(Marshall.Compute.LifecycleEvent, :expire,
            action_arguments: %{continuation: Ash.UUID.generate()}
          )
        end

        count
      end)

    case result do
      {:ok, count} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("lifecycle.retention_deleted", deleted_count: count)
        end

        {:ok, count}

      other ->
        other
    end
  end

  @spec expire_version_table(String.t(), non_neg_integer()) :: {:cont, non_neg_integer()}
  defp expire_version_table(table, total) do
    # Table names come exclusively from the compile-time allowlist above.
    %{num_rows: removed} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        WITH expired AS (
          SELECT id FROM #{table}
          WHERE version_inserted_at <= clock_timestamp() - interval '90 days'
          ORDER BY version_inserted_at, id LIMIT $1 FOR UPDATE SKIP LOCKED
        ) DELETE FROM #{table} e USING expired x WHERE e.id = x.id
        """,
        [1000 - total],
        log: false
      )

    {:cont, total + removed}
  end
end
