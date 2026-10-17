defmodule Galileo.Control do
  @moduledoc """
  Galileo's control link to Marshall: one verified WebSocket (ADR-0142).

  `Galileo.Control.Link` owns a `OverallsProtocol.Control.Client` named
  `Galileo.ControlClient`. Requests never retry or queue: a request without a
  welcomed connection, or one whose connection drops, is an authority outage.
  """
  require Galileo.Events

  alias OverallsProtocol.Control.Client

  @type t :: %{required(:client) => GenServer.server(), optional(atom()) => term()}
  @type result ::
          {:ok, map()} | {:error, :unauthorized | :authority_unavailable | :unsupported_version}

  # @cc [owner:ghuntley,label:recovery] galileo-version-refusal-terminal
  # A Marshall version refusal (HTTP 426 at upgrade, or close 4001) MUST keep
  # a distinct permanent class; renewal MUST close the attempt. Unauthorized
  # stays a refusal and never becomes an authority outage.
  # Pending unproven calls retired by close4001 MUST preserve the stopped
  # client's unsupported_version reason; other losses remain authority outages.
  @spec request(t(), binary(), map()) :: result()
  def request(%{client: client}, route, body) when route in ["authorize", "identity", "renew"] do
    response =
      case Client.request(client, "galileo." <> route, body, 5_000) do
        {:ok, object} -> {:ok, object}
        {:error, "unauthorized"} -> {:error, :unauthorized}
        {:error, reason} when reason in [:disconnected, :unproven] -> disconnected(client)
        {:error, _reason} -> {:error, :authority_unavailable}
      end

    if response == {:error, :unsupported_version},
      do: Galileo.Events.emit("galileo.control_version_refused", reason: route_reason(route))

    response
  catch
    :exit, _ -> {:error, :authority_unavailable}
  end

  @spec disconnected(GenServer.server()) :: result()
  defp disconnected(client) do
    case Client.status(client) do
      {:disconnected, :unsupported_version} -> {:error, :unsupported_version}
      {:disconnected, :refused} -> {:error, :unauthorized}
      _ -> {:error, :authority_unavailable}
    end
  end

  @spec route_reason(binary()) :: atom()
  defp route_reason("authorize"), do: :authorize
  defp route_reason("identity"), do: :identity
  defp route_reason("renew"), do: :renew

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
          service: "galileo",
          credential: fn -> {:ok, control.token} end,
          bind: fn -> %{} end,
          cacertfile: control.ca_file,
          owner: self()
        )

      {:ok, control}
    end

    # Galileo holds no pushed state; connection events need no reaction.
    @impl true
    def handle_info({:control, _client, _event}, state), do: {:noreply, state}
    def handle_info(_message, state), do: {:noreply, state}
  end
end
