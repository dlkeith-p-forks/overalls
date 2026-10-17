defmodule Marshall.Compute.ServiceLevelPublisher do
  @moduledoc "Bounded reliability reconciliation and private numeric publication."
  use GenServer
  require Ash.Query
  require Marshall.Events
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Ledger,
    ServiceLevelAttempt,
    ServiceLevels,
    ServiceLevelTotal,
    ServiceLevelTotals
  }

  @services [
    :lilly_physical,
    :marshall_ready,
    :porsche_physical,
    :porsche_clone,
    :porsche_relocate,
    :porsche_retry,
    :porsche_cancel
  ]
  @type state :: %{directory: Path.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    directory = Keyword.get(opts, :directory)
    if is_binary(directory), do: send(self(), :publish)
    {:ok, %{directory: directory}}
  end

  # @cc [owner:ghuntley,label:security;reliability] service-level-publication-custody
  # Publication MUST contain only the fixed numeric aggregate schema, use
  # atomic mode-0640 source-group files and retain database lifetime identities.
  # Failed reconciliation or publication MUST remove current snapshots; it
  # MUST NOT refresh sampling clocks from cached data. Diagnostics MUST remain
  # fixed and carry no database errors, paths, payloads or credential material.
  @impl true
  def handle_info(:publish, %{directory: directory} = state) when is_binary(directory) do
    case publish(directory) do
      :ok ->
        :ok

      :error ->
        Enum.each(@services, &File.rm(Path.join(directory, "#{&1}.json")))
        Marshall.Events.emit("telemetry.service_levels_unavailable", [])
    end

    Process.send_after(self(), :publish, 5_000)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:accounting;reliability] service-level-backlog-withholds-freshness
  # Publication MUST refuse fresh snapshots if any pending attempt is overdue
  # at the database sampling time after bounded reconciliation. It MUST retain
  # committed terminal totals and original deadlines for a subsequent scan.
  @spec publish(Path.t()) :: :ok | :error
  def publish(directory) do
    try do
      with {:ok, _} <- ServiceLevels.reconcile(),
           {:ok, _} <- Marshall.Compute.WorkflowServiceLevels.reconcile(),
           {:ok, snapshots} <-
             Ledger.transaction(fn ->
               now = Ledger.now()

               if ServiceLevelAttempt
                  |> Ash.Query.filter(status == :pending and deadline <= ^now)
                  |> Ash.exists?(actor: SystemActor.compute()) do
                 Ledger.rollback(:service_level_backlog)
               end

               if Marshall.Compute.WorkflowServiceLevelAttempt
                  |> Ash.Query.filter(status == :pending and deadline <= ^now)
                  |> Ash.exists?(actor: SystemActor.compute()) do
                 Ledger.rollback(:workflow_service_level_backlog)
               end

               Enum.each(@services, &ServiceLevelTotals.ensure!/1)

               ServiceLevelTotal
               |> Ash.Query.filter(service in ^@services)
               |> Ash.read!(actor: SystemActor.compute())
               |> Enum.map(&ServiceLevelTotals.snapshot(&1, now))
             end) do
        Enum.each(snapshots, fn snapshot ->
          path = Path.join(directory, "#{snapshot.service}.json")
          temporary = path <> ".tmp"
          bytes = Jason.encode!(snapshot)
          :ok = File.write(temporary, bytes, [:binary])
          :ok = File.chmod(temporary, 0o640)
          :ok = File.rename(temporary, path)
        end)

        :ok
      else
        _ -> :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end
end
