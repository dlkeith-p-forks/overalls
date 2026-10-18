defmodule Marshall.Ingress.EditorAssets do
  @moduledoc "Authenticate an asset readiness acknowledgment without trusting request destinations."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, HostLiveness, Ledger}
  alias Marshall.Ingress.{EditorAssetsReceipt, Error, Services}
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> report!(input.arguments) end) |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  @spec report!(map()) :: map()
  defp report!(request) do
    service = Services.authenticate!(request.service_token, :exclusive)

    unless service.role == :gateway and service.addresses != [] and
             is_binary(service.ssh_host_key),
           do: Ledger.rollback(:unauthorized)

    host =
      Host
      |> Ash.Query.filter(id == ^service.host_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || Ledger.rollback(:unauthorized)

    unless host.enabled and host.maintenance_mode != :retired and
             HostLiveness.authority?(host.connection_session_id, host.reported_at, Ledger.now()),
           do: Ledger.rollback(:unauthorized)

    descriptor = %{
      "protocol" => request.editor_protocol,
      "commit" => request.editor_commit,
      "release" => request.editor_release
    }

    with {:ok, approved} <- OverallsProtocol.EditorRelease.decode(descriptor),
         true <-
           Marshall.Editor.Releases.approved?(approved, Marshall.Editor.Releases.configured()) do
      :ok
    else
      _ -> Ledger.rollback(:image_unavailable)
    end

    binding = [
      service_id: service.id,
      service_generation: service.generation,
      session_id: host.connection_session_id,
      editor_protocol: request.editor_protocol,
      editor_commit: request.editor_commit,
      editor_release: request.editor_release
    ]

    case Ledger.read!(EditorAssetsReceipt, binding) do
      [] ->
        Ledger.create!(
          EditorAssetsReceipt,
          :record,
          Map.new(binding)
          |> Map.put(:host_id, host.id)
          |> Map.merge(Map.take(request, [:editor_protocol, :editor_commit, :editor_release]))
          |> Map.put(:expires_at, DateTime.add(Ledger.now(), 5))
        )

        Ledger.after_commit(fn ->
          Marshall.Events.emit("editor.assets_ready", host_id: host.id)
        end)

      [receipt] ->
        unless Map.take(receipt, [:editor_protocol, :editor_commit, :editor_release]) ==
                 Map.take(request, [:editor_protocol, :editor_commit, :editor_release]),
               do: Ledger.rollback(:image_unavailable)

        Ledger.update!(receipt, :refresh, %{expires_at: DateTime.add(Ledger.now(), 5)})
    end

    Map.take(request, [:editor_protocol, :editor_commit, :editor_release])
  end
end
