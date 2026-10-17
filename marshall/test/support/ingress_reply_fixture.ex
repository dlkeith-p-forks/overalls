defmodule Marshall.IngressReplyFixture do
  @moduledoc """
  Test-only control endpoint with a fixed reply (ADR-0142).

  With status 200 it upgrades `/api/control/v1` and answers every request with
  the JSON document `body` (a non-JSON body answers "unavailable"). Any other
  status refuses the upgrade itself with that status and headers, as an old or
  redirecting server would. The owner receives `:request_received` for each
  upgrade attempt and each request.
  """
  @behaviour Plug
  import Plug.Conn

  alias OverallsProtocol.Control.Envelope

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, {owner, 200, body, _headers}), do: upgrade(conn, {owner, body, 0})

  def call(conn, {owner, 200, body, _headers, delay}) when delay in 1..1000,
    do: upgrade(conn, {owner, body, delay})

  def call(conn, {owner, status, _body, headers}) do
    send(owner, :request_received)

    Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
    |> send_resp(status, "")
  end

  @spec upgrade(Plug.Conn.t(), {pid(), binary(), non_neg_integer()}) :: Plug.Conn.t()
  defp upgrade(conn, state) do
    conn
    |> upgrade_adapter(:websocket, {__MODULE__.Socket, state, []})
    |> halt()
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({text, [opcode: :text]}, {owner, body, delay} = state) do
      case Envelope.decode(text) do
        {:ok, {:hello, _hello}} ->
          welcome = %{conn: "reply", heartbeat_ms: 5_000, limits: %{}}
          {:push, {:text, Envelope.encode({:welcome, welcome})}, state}

        {:ok, {:req, %{id: id}}} ->
          send(owner, :request_received)
          if delay > 0, do: Process.sleep(delay)
          {:push, {:text, Envelope.encode({:res, %{id: id, result: result(body)}})}, state}

        {:ok, {:ping, n}} ->
          {:push, {:text, Envelope.encode({:pong, n})}, state}

        _ ->
          {:ok, state}
      end
    end

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @spec result(binary()) :: {:ok, map()} | {:error, String.t()}
    defp result(body) do
      case JSON.decode(body) do
        {:ok, value} when is_map(value) -> {:ok, value}
        _ -> {:error, "unavailable"}
      end
    end
  end
end
