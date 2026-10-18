Code.require_file("../../../scripts/test/hegel_fixtures.exs", __DIR__)

defmodule Audi.Test.DNSControl do
  @external_resource Path.expand("../../../scripts/test/hegel_fixtures.exs", __DIR__)
  @moduledoc """
  Test-only Marshall control WebSocket for Audi (ADR-0142).

  Each request reaches the owner as
  `{:control_request, pid, ref, "/api/audi/v1/<route>", ["Bearer " <> token], body}`
  and is answered by `send(pid, {ref, status, json})` using the HTTP status
  classes Marshall maps to control errors.
  """
  @behaviour Plug
  import Plug.Conn

  alias OverallsProtocol.Control.Envelope

  @impl true
  def init(options), do: options

  @impl true
  def call(%{request_path: "/api/control/v1"} = conn, options) do
    authorization = get_req_header(conn, "authorization")

    case Keyword.get(options, :upgrade_refusal) do
      body when is_binary(body) ->
        send(Keyword.fetch!(options, :owner), {:control_upgrade_refused, byte_size(body)})
        conn |> send_resp(426, body) |> halt()

      nil ->
        conn
        |> upgrade_adapter(
          :websocket,
          {__MODULE__.Socket, {Keyword.fetch!(options, :owner), authorization}, []}
        )
        |> halt()
    end
  end

  def call(conn, _options), do: send_resp(conn, 404, "")

  @doc "Starts the client's control link and waits for its welcome."
  @spec connected(Audi.Control.Client.t()) :: Audi.Control.Client.t()
  def connected(client) do
    client = started(client)
    wait(client.control, 100)
    client
  end

  # @cc [owner:ghuntley,label:verification;protocol] audi-owned-upgrade-refusal-client
  # Starting the owned link MUST NOT require a welcome, so an actual refused
  # upgrade can be observed through the application client without a fake response.
  @spec started(Audi.Control.Client.t()) :: Audi.Control.Client.t()
  def started(client) do
    client = %{client | control: :"audi_control_#{System.unique_integer([:positive])}"}
    Overalls.HegelFixtures.start_fixture!({Audi.Control.Link, client}, id: client.control)
    client
  end

  @spec wait(atom(), non_neg_integer()) :: :ok
  defp wait(control, 0), do: raise("control client #{control} never connected")

  defp wait(control, attempts) do
    if Process.whereis(control) && OverallsProtocol.Control.Client.ready?(control) do
      :ok
    else
      Process.sleep(20)
      wait(control, attempts - 1)
    end
  end

  @doc false
  @spec result(pos_integer(), binary()) :: {:ok, map()} | {:error, String.t()}
  def result(200, reply) do
    case JSON.decode(reply) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "unavailable"}
    end
  end

  def result(401, reply) do
    case JSON.decode(reply) do
      {:ok, %{"error" => "authentication_required"}} -> {:error, "authentication_required"}
      _ -> {:error, "unauthorized"}
    end
  end

  def result(403, _reply), do: {:error, "forbidden"}
  def result(413, _reply), do: {:error, "message_too_large"}
  def result(426, _reply), do: {:error, "unsupported_version"}
  def result(_status, _reply), do: {:error, "unavailable"}

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({text, [opcode: :text]}, {owner, authorization} = state) do
      case Envelope.decode(text) do
        {:ok, {:hello, %{service: "audi"}}} ->
          welcome = %{conn: "stub", heartbeat_ms: 5_000, limits: %{"in_flight" => 64}}
          {:push, {:text, Envelope.encode({:welcome, welcome})}, state}

        {:ok, {:req, %{id: id, op: "audi." <> route, body: body}}} ->
          socket = self()

          spawn(fn ->
            monitor = Process.monitor(socket)
            reference = make_ref()

            send(
              owner,
              {:control_request, self(), reference,
               "/api/audi/v1/" <> String.replace(route, "_", "-"), authorization, body}
            )

            result =
              receive do
                {^reference, :close, code} when code in 4000..4008 -> {:close, code}
                {^reference, status, reply} -> Audi.Test.DNSControl.result(status, reply)
                {:DOWN, ^monitor, :process, ^socket, _reason} -> :retired
              after
                4_000 -> {:error, "unavailable"}
              end

            if result != :retired, do: send(socket, {:result, id, result})
          end)

          {:ok, state}

        {:ok, {:ping, n}} ->
          {:push, {:text, Envelope.encode({:pong, n})}, state}

        _ ->
          {:ok, state}
      end
    end

    @impl true
    def handle_info({:result, _id, {:close, code}}, state) when code in 4000..4008,
      do: {:stop, :normal, {code, ""}, state}

    def handle_info({:result, id, result}, state),
      do: {:push, {:text, Envelope.encode({:res, %{id: id, result: result}})}, state}

    def handle_info(_message, state), do: {:ok, state}
  end
end
