defmodule Audi.Control.Link do
  @moduledoc """
  Owns Audi's control WebSocket (ADR-0142): one `OverallsProtocol.Control.Client`
  per role, named by the configured `Audi.Control.Client`, bound to the
  credential's role and host.
  """
  use GenServer

  @frame 8_388_608 + 1_024

  @spec start_link(Audi.Control.Client.t()) :: GenServer.on_start()
  def start_link(client), do: GenServer.start_link(__MODULE__, client)

  @impl true
  def init(client) do
    {:ok, _socket} =
      OverallsProtocol.Control.Client.start_link(
        name: client.control,
        url: client.origin,
        service: "audi",
        credential: fn -> {:ok, client.token} end,
        bind: fn -> %{"role" => Atom.to_string(client.role), "host_id" => client.host_id} end,
        cacertfile: client.cacertfile,
        limit: @frame,
        owner: self()
      )

    {:ok, client}
  end

  # @cc [owner:ghuntley,label:protocol;recovery] audi-control-hint-dispatch
  # A hint MUST only wake the local readers registered for its kind under
  # Audi.Control.Hints; each reader keeps its own cadence as the backstop, so
  # a lost or duplicate hint changes latency only. Other events need no reaction.
  @impl true
  def handle_info({:control, _socket, {:hint, kind, id}}, client) do
    if Process.whereis(Audi.Control.Hints) do
      # Kind-wide readers (the route catalog) and per-identity readers (stream
      # leases for one VM or user) register under separate keys.
      for key <- [kind, {kind, id}] do
        Registry.dispatch(Audi.Control.Hints, key, fn entries ->
          for {pid, _} <- entries, do: send(pid, {:control_hint, kind, id})
        end)
      end
    end

    {:noreply, client}
  end

  def handle_info({:control, _socket, _event}, client), do: {:noreply, client}
  def handle_info(_message, client), do: {:noreply, client}
end
