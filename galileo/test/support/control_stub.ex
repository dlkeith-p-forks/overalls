defmodule Galileo.ControlStub do
  @moduledoc """
  Test-only Marshall control WebSocket over verified TLS.

  `start/1` takes a responder `(op, body -> {:ok, map} | {:error, String.t()})`
  or `{:refuse, status}` to answer the upgrade with an HTTP status, and returns
  a control map whose client is connected (or has seen the refusal).
  """

  alias OverallsProtocol.Control.{Client, Envelope}

  @fixtures Path.expand("../../../marshall/test/fixtures/tls", __DIR__)

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl true
    def init(options), do: options

    @impl true
    def call(%{request_path: "/api/control/v1"} = conn, {owner, {:refuse, status}}) do
      send(owner, {:control_path, conn.request_path})
      Elixir.Plug.Conn.send_resp(conn, status, String.duplicate("x", 20_000))
    end

    def call(%{request_path: "/api/control/v1"} = conn, {owner, responder}) do
      send(owner, {:control_path, conn.request_path})

      conn
      |> Elixir.Plug.Conn.upgrade_adapter(
        :websocket,
        {Galileo.ControlStub.Socket, {owner, responder}, []}
      )
      |> Elixir.Plug.Conn.halt()
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({text, [opcode: :text]}, {owner, responder} = state) do
      case Envelope.decode(text) do
        {:ok, {:hello, %{service: "galileo"}}} ->
          welcome = %{conn: "stub", heartbeat_ms: 5_000, limits: %{}}
          {:push, {:text, Envelope.encode({:welcome, welcome})}, state}

        {:ok, {:req, %{id: id, op: op, body: body}}} ->
          send(owner, {:control_request, op})

          {:push, {:text, Envelope.encode({:res, %{id: id, result: responder.(op, body)}})},
           state}

        {:ok, {:ping, n}} ->
          {:push, {:text, Envelope.encode({:pong, n})}, state}

        _ ->
          {:ok, state}
      end
    end

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  @spec start((String.t(), map() -> {:ok, map()} | {:error, String.t()}) | {:refuse, 100..599}) ::
          map()
  def start(responder) do
    owner = self()

    endpoint =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__.Plug, {owner, responder}},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(endpoint)

    client =
      ExUnit.Callbacks.start_supervised!(
        {Client,
         [
           url: "https://localhost:#{port}",
           service: "galileo",
           credential: fn -> {:ok, "fixture-token"} end,
           bind: fn -> %{} end,
           cacertfile: Path.join(@fixtures, "ca.pem"),
           owner: owner
         ]},
        id: make_ref()
      )

    await(client, responder)
    %{client: client}
  end

  @spec await(pid(), term()) :: :ok
  defp await(client, {:refuse, _status}) do
    wait(fn -> match?({:disconnected, reason} when reason != nil, Client.status(client)) end)
  end

  defp await(client, _responder), do: wait(fn -> Client.status(client) == :ready end)

  @spec wait((-> boolean()), non_neg_integer()) :: :ok
  defp wait(check, attempts \\ 200) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        raise "control stub client did not settle"

      true ->
        Process.sleep(25)
        wait(check, attempts - 1)
    end
  end
end
