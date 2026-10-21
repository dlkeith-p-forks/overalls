defmodule Peach.Control do
  @moduledoc """
  Peach's control link to Marshall: one verified WebSocket (ADR-0142).

  `Peach.Control.Link` owns an `OverallsProtocol.Control.Client`. Requests
  never retry, queue or fall back to a retained snapshot: a request without a
  welcomed connection is an authority outage.
  """
  alias OverallsProtocol.Control.Client

  @type t :: %{required(:client) => GenServer.server(), optional(atom()) => term()}

  @spec snapshot(t(), map()) :: {:ok, map()} | {:error, :refused | :unavailable}
  def snapshot(%{client: client}, binding) do
    case Client.request(client, "peach.snapshot", %{"version" => 1, "binding" => binding}, 2_000) do
      {:ok, object} when is_map(object) -> {:ok, object}
      {:error, "invalid_request"} -> {:error, :refused}
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defmodule Link do
    @moduledoc "Owns the control client and absorbs its connection events."
    use GenServer

    @spec start_link(map()) :: GenServer.on_start()
    def start_link(control), do: GenServer.start_link(__MODULE__, control, name: __MODULE__)

    @impl true
    def init(control) do
      {:ok, _client} =
        Client.start_link(
          name: control.client,
          url: control.origin,
          service: "peach",
          credential: fn -> {:ok, control.token} end,
          bind: fn -> %{"host_id" => control.host_id} end,
          cacertfile: control.ca_file,
          owner: self()
        )

      {:ok, control}
    end

    # Peach holds no pushed state; connection events need no reaction.
    @impl true
    def handle_info(_message, state), do: {:noreply, state}
  end
end
