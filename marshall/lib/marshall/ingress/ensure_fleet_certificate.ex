defmodule Marshall.Ingress.EnsureFleetCertificate do
  @moduledoc "Create at most one due wildcard generation with its Oban job."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Error, FleetCertificate}
  require Marshall.Events

  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> ensure_due!() end) |> Error.result()
  rescue
    _ -> {:error, Error.exception(reason: :unavailable)}
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:concurrency;recovery] fleet-renewal-single-admission
  # Every Marshall replica may invoke this action. The database lock and one
  # transaction MUST serialize generation allocation with AshOban enqueue.
  # A pending order blocks another until an explicit terminal decision.
  @spec ensure_due!() :: 0 | 1
  def ensure_due! do
    if allocate!(false), do: 1, else: 0
  end

  @doc "Allocate one new generation regardless of renewal date, under the caller's transaction."
  @spec rotate!(String.t()) :: FleetCertificate.t()
  def rotate!(actor_id) do
    certificate = allocate!(true)

    Ledger.after_commit(fn ->
      Marshall.Events.emit("ingress.fleet_certificate_rotation_requested",
        certificate_id: certificate.id,
        generation: certificate.generation,
        actor_id: actor_id
      )
    end)

    certificate
  end

  # @cc [owner:ghuntley,label:concurrency;security;recovery] fleet-rotation-serialized
  # Scheduled renewal and emergency rotation MUST share the advisory lock and
  # pending-generation exclusion. An operator request MUST NOT bypass a pending
  # order, replace the active certificate early, or enqueue duplicate work.
  @spec allocate!(boolean()) :: FleetCertificate.t() | nil
  defp allocate!(force?) do
    config = Application.get_env(:marshall, :fleet_acme)
    zone = Application.get_env(:marshall, :ingress_zone)

    unless is_map(config) and config.zone == zone and is_binary(zone),
      do: Ledger.rollback(:unavailable)

    Marshall.Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["audi-wildcard:" <> zone]
    )

    %{rows: [[generation, due, pending]]} =
      Marshall.Repo.query!(
        """
        SELECT COALESCE(MAX(generation), 0),
          COALESCE(BOOL_OR(
            expires_at <= (statement_timestamp() AT TIME ZONE 'UTC') +
              LEAST(interval '21 days', (expires_at - updated_at) / 3)
          ) FILTER (WHERE status = 'active'), true),
          COUNT(*) FILTER (WHERE status IN ('pending', 'challenging', 'issued'))
        FROM ingress_fleet_certificates WHERE zone = $1
        """,
        [zone]
      )

    cond do
      pending != 0 and force? ->
        Ledger.rollback(:already_pending)

      pending != 0 or (not due and not force?) ->
        nil

      true ->
        Ledger.create!(FleetCertificate, :enqueue, %{
          generation: generation + 1,
          zone: zone
        })
    end
  end
end
