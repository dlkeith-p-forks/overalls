defmodule Marshall.Ingress.Catalog do
  @moduledoc "Bounded local workload discovery for certificate workers; not access authority."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger}
  alias Marshall.Ingress.{Error, Services}
  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] ingress-gateway-catalog
  # Catalogs MUST authenticate a current gateway and return only its host's
  # current wake-eligible placements and retained enrolled relay origins, with
  # immutable VM/placement/execution identity.
  # Missing or stale host authority and inventory overflow MUST fail the whole
  # request. The bounded statement is discovery only; route reports MUST independently revalidate the current wake projection;
  # stream admission MUST independently prove running execution.
  # Entries MUST NOT carry the retired `certificate_id` key (ADR-0159); retired
  # issuance archives MUST NOT be consulted.
  @impl true
  def run(input, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> catalog!(input.arguments.token) end) |> Error.result()
  rescue
    _ -> {:error, Error.exception(reason: :unavailable)}
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp catalog!(token) do
    %{rows: [[statement_timeout, lock_timeout]]} =
      sql!("SELECT current_setting('statement_timeout'), current_setting('lock_timeout')", [])

    sql!(
      "SELECT set_config('statement_timeout', '1500ms', true), set_config('lock_timeout', '1000ms', true)",
      []
    )

    service = Services.authenticate!(token)

    unless service.role == :gateway and service.addresses != [] and
             is_binary(service.ssh_host_key),
           do: Ledger.rollback(:unauthorized)

    host =
      Host
      |> Ash.Query.filter(id == ^service.host_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute())

    unless host && host.enabled && host.maintenance_mode != :retired &&
             is_binary(host.connection_session_id) &&
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               Ledger.now()
             ),
           do: Ledger.rollback(:unauthorized)

    %{rows: rows} =
      sql!(
        """
        SELECT v.id::text, p.id::text, v.execution_epoch, v.generation, e.label
        FROM compute_virtual_machines v
        JOIN compute_workload_placements p ON p.id = v.current_placement_id AND p.vm_id = v.id
        JOIN ingress_endpoints e ON e.vm_id = v.id
        WHERE v.archived_at IS NULL AND v.desired_state IN ('running', 'paused')
          AND v.observed_state NOT IN ('deleted', 'failed')
          AND (p.host_id = $1::text::uuid OR EXISTS (
            SELECT 1 FROM ingress_routes r
            JOIN ingress_services origin ON origin.id = r.service_id
            JOIN ingress_services destination ON destination.host_id = p.host_id
            WHERE r.vm_id = v.id AND origin.id = $2::text::uuid
              AND origin.enabled AND origin.role = 'gateway' AND origin.relay_address IS NOT NULL
              AND destination.enabled AND destination.role = 'gateway'
              AND destination.relay_address IS NOT NULL
          ))
        ORDER BY v.id LIMIT 10001
        """,
        [service.host_id, service.id]
      )

    if length(rows) > 10_000, do: Ledger.rollback(:capacity)

    entries =
      Enum.map(rows, fn [vm, placement, epoch, generation, label] ->
        %{
          vm_id: vm,
          placement_id: placement,
          execution_epoch: epoch,
          generation: generation,
          label: label
        }
      end)

    sql!(
      "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)",
      [statement_timeout, lock_timeout]
    )

    %{
      service_id: service.id,
      host_id: service.host_id,
      service_generation: service.generation,
      ttl: 5000,
      entries: entries
    }
  end

  defp sql!(statement, params),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, params, log: false)
end
