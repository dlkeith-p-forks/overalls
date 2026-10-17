defmodule Porsche.Control.Link do
  @moduledoc """
  Owns Porsche's control WebSocket (ADR-0142): one `OverallsProtocol.Control.Client`,
  named by the configured `Porsche.Client`, bound to the credential's gateway.
  """
  use GenServer

  @frame 1_048_576 + 4_096

  @spec start_link(Porsche.Client.t()) :: GenServer.on_start()
  def start_link(client), do: GenServer.start_link(__MODULE__, client)

  @impl true
  def init(client) do
    {:ok, _socket} =
      OverallsProtocol.Control.Client.start_link(
        name: client.control,
        url: client.origin,
        service: "porsche",
        credential: fn -> {:ok, client.token} end,
        bind: fn -> %{} end,
        cacertfile: client.cacertfile,
        limit: @frame,
        owner: self()
      )

    {:ok, client}
  end

  # Sessions and commands re-read on demand until approval hints drive them.
  @impl true
  def handle_info({:control, _socket, _event}, client), do: {:noreply, client}
  def handle_info(_message, client), do: {:noreply, client}
end
