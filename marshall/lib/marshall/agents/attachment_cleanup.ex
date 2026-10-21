defmodule Marshall.Agents.AttachmentCleanup do
  @moduledoc "Periodic reclamation of abandoned, non-published attachment uploads."
  use GenServer
  require Marshall.Events

  @interval_ms 60_000
  @retention_seconds 86_400

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    send(self(), :reap)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reap, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)

    try do
      Marshall.Agents.AttachmentTransfers.expire_abandoned(cutoff)
    rescue
      _ -> Marshall.Events.emit("attachment.cleanup_failed", reason: :exception)
    end

    Process.send_after(self(), :reap, @interval_ms)
    {:noreply, state}
  end
end
