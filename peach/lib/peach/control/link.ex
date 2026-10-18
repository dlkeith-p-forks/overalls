defmodule Peach.Control.Link do
  use GenServer
  def start_link(control), do: GenServer.start_link(__MODULE__, control, name: __MODULE__)
  @impl true
  def init(control) do
    {:ok, _} =
      OverallsProtocol.Control.Client.start_link(
        name: Peach.Control.Client,
        url: control.origin,
        service: "peach",
        credential: fn -> {:ok, control.token} end,
        bind: fn -> %{"host_id" => control.host_id} end,
        cacertfile: control.ca_file,
        owner: self()
      )

    {:ok, control}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}
end
