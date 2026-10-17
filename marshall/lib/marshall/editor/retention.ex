defmodule Marshall.Editor.Retention do
  @moduledoc "Bounded expiry of operational editor authority, retaining audit versions."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Editor.{Credential, Lease, Login}
  require Ash.Query

  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)
      leases = purge(Lease, cutoff, 200)
      credentials = Credential |> Ash.Query.filter(not exists(leases, true))
      credentials = purge(credentials, cutoff, 100)
      logins = purge(Login, cutoff, 100)
      receipts = purge(Marshall.Ingress.EditorAssetsReceipt, cutoff, 100)

      if leases == 200 or credentials == 100 or logins == 100 or receipts == 100 do
        AshOban.schedule(Lease, :prune, action_arguments: %{continuation: Ash.UUID.generate()})
      end

      leases + credentials + logins + receipts
    end)
    |> Marshall.Ingress.Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  @spec purge(module() | Ash.Query.t(), DateTime.t(), pos_integer()) :: non_neg_integer()
  defp purge(query, cutoff, limit) do
    records =
      query
      |> Ash.Query.filter(expires_at < ^cutoff)
      |> Ash.Query.sort(expires_at: :asc, id: :asc)
      |> Ash.Query.limit(limit)
      |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
      |> Ash.read!(actor: SystemActor.compute())

    Enum.each(records, &Ledger.archive!(&1, :purge))
    length(records)
  end
end
