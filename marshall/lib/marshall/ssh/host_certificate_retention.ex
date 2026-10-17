defmodule Marshall.SSH.HostCertificateRetention do
  @moduledoc "Bounded cleanup of public certificate history; deletion does not revoke certificates."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.HostCertificate
  require Ash.Query
  @batch 500

  # @cc [owner:ghuntley,label:recovery] ssh-certificate-history-retention
  # Cleanup MUST preserve unexpired current certificates and seven days of
  # superseded/expired history. Each transaction MUST delete at most 500 records
  # and schedule a durable continuation when the batch is full.
  @impl true
  def run(_, _, _) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)
      expiry = DateTime.to_unix(cutoff)

      records =
        HostCertificate
        |> Ash.Query.filter(
          (status == :superseded and updated_at < ^cutoff) or valid_before < ^expiry
        )
        |> Ash.Query.sort(valid_before: :asc, id: :asc)
        |> Ash.Query.limit(@batch)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      Enum.each(records, &Ledger.archive!(&1, :purge))
      count = length(records)

      if count == @batch do
        AshOban.schedule(HostCertificate, :prune,
          action_arguments: %{continuation: Ash.UUID.generate()}
        )
      end

      count
    end)
    |> Marshall.SSH.Error.result()
  end
end
