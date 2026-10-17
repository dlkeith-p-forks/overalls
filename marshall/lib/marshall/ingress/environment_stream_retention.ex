defmodule Marshall.Ingress.EnvironmentStreamRetention do
  @moduledoc "Bounded expired nested stream cleanup, preserving audits."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{EnvironmentStream, Error}
  require Ash.Query

  # @cc [owner:ghuntley,label:recovery] inception-stream-retention
  # A transaction MUST purge at most 500 stream rows expired for seven days,
  # skip locked rows and retain audit history. A full batch MUST schedule its
  # continuation in the same transaction.
  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)

      rows =
        EnvironmentStream
        |> Ash.Query.filter(expires_at < ^cutoff)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(500)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      Enum.each(rows, &Ledger.archive!(&1, :purge))

      if length(rows) == 500 do
        AshOban.schedule(EnvironmentStream, :prune,
          action_arguments: %{continuation: Ash.UUID.generate()}
        )
      end

      length(rows)
    end)
    |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
