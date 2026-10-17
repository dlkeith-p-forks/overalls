defmodule Ziggy.Control.Link do
  @moduledoc """
  Owns Ziggy's control WebSocket (ADR-0142): one `OverallsProtocol.Control.Client`,
  named by the configured control client, bound to the credential's host.
  """
  use GenServer

  # agent_result requests carry responses up to 1,048,576 bytes.
  @frame 1_100_000 + 4_096

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(control), do: GenServer.start_link(__MODULE__, control)

  @impl true
  def init(control) do
    {:ok, _socket} =
      OverallsProtocol.Control.Client.start_link(
        name: control.client,
        url: control.origin,
        service: "ziggy",
        credential: fn -> {:ok, control.token} end,
        bind: fn -> %{"host_id" => control.host_id} end,
        cacertfile: control.ca_file,
        limit: @frame,
        owner: self()
      )

    {:ok, control}
  end

  # The agent worker and reporter keep their own cadence until work hints
  # drive them.
  @impl true
  # @cc [owner:ghuntley,label:protocol;recovery] ziggy-work-hint
  # A ziggy_work hint MUST only ask the agent worker to claim once now; its
  # periodic poll and version fence remain, so a lost or duplicate hint
  # changes latency only.
  def handle_info({:control, _socket, {:hint, "ziggy_work", _id}}, control) do
    case Process.whereis(Ziggy.AgentWorker) do
      nil -> :ok
      worker -> send(worker, :work_hinted)
    end

    {:noreply, control}
  end

  def handle_info({:control, _socket, _event}, control), do: {:noreply, control}
  def handle_info(_message, control), do: {:noreply, control}
end
