defmodule Lilly.Control.Link do
  @moduledoc """
  Owns Lilly's control WebSocket (ADR-0142): one `OverallsProtocol.Control.Client`,
  named by the configured `Lilly.Control.Client`, bound to the credential's host.
  """
  use GenServer

  @frame OverallsProtocol.max_body() + 4_096

  @spec start_link(Lilly.Control.Client.t()) :: GenServer.on_start()
  def start_link(client), do: GenServer.start_link(__MODULE__, client)

  @impl true
  def init(client) do
    {:ok, _socket} =
      OverallsProtocol.Control.Client.start_link(
        name: client.control,
        url: client.base_url,
        service: "lilly",
        credential: fn -> {:ok, client.token} end,
        bind: fn -> %{"host_id" => client.host_id} end,
        cacertfile: client.cacertfile,
        allow_insecure_loopback: client.allow_insecure_loopback,
        limit: @frame,
        owner: self()
      )

    {:ok, client}
  end

  # @cc [owner:ghuntley,label:protocol;recovery] lilly-host-commands-hint
  # A host_commands hint MUST only ask the runtime to exchange now; the
  # runtime keeps its own coalescing, fencing and periodic exchange, so a lost
  # or duplicate hint changes latency only. Other events need no reaction.
  @impl true
  def handle_info({:control, _socket, {:hint, "host_commands", _id}}, client) do
    case Process.whereis(Lilly.Control.Runtime) do
      nil -> :ok
      runtime -> send(runtime, :commands_hinted)
    end

    {:noreply, client}
  end

  def handle_info({:control, _socket, _event}, client), do: {:noreply, client}
  def handle_info(_message, client), do: {:noreply, client}
end
