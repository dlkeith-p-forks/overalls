defmodule Ziggy.ArtifactChunkTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  defmodule Authority do
    use GenServer
    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    @spec init(pid()) :: {:ok, pid()}
    def init(owner), do: {:ok, owner}
    @impl true
    @spec handle_call(term(), GenServer.from(), pid()) :: {:reply, term(), pid()}
    def handle_call({:request, operation, body, _timeout}, _from, owner) do
      send(owner, {:authority, operation, body})
      {:reply, {:ok, %{"accepted" => true}}, owner}
    end
  end

  @host "11111111-1111-4111-8111-111111111111"
  @limit 270_336
  @binding %{
    "host_id" => @host,
    "vm_id" => @host,
    "placement_id" => @host,
    "execution_epoch" => 1
  }

  setup do
    authority = start_supervised!({Authority, self()})
    %{config: %{host_id: @host, control: %{client: authority}}}
  end

  @spec post(String.t(), binary()) :: Plug.Conn.t()
  defp post(path, body) do
    Plug.Test.conn(:post, "http://llm.internal" <> path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "x-overalls-binding",
      Base.url_encode64(Jason.encode!(@binding), padding: false)
    )
  end

  @spec chunk(non_neg_integer()) :: map()
  defp chunk(bytes) do
    %{
      "executor_id" => @host,
      "fence_epoch" => 1,
      "command_id" => @host,
      "publish_request_id" => @host,
      "file_index" => 0,
      "chunk_index" => 0,
      "sha256" => String.duplicate("a", 64),
      "data" => Base.encode64(:binary.copy(<<0>>, bytes))
    }
  end

  @spec padded(pos_integer()) :: binary()
  defp padded(size) do
    body = Jason.encode!(chunk(1))
    body <> String.duplicate(" ", size - byte_size(body))
  end

  test "a full chunk is relayed to agent_artifact_chunk with Audi's binding", %{config: config} do
    input = chunk(196_608)
    body = Jason.encode!(input)
    assert byte_size(body) > 12_288 and byte_size(body) <= @limit

    response = Ziggy.HTTP.call(post("/agent/v1/artifact_chunk", body), config)

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"accepted" => true}
    assert_received {:authority, "ziggy.agent_artifact_chunk", forwarded}
    assert forwarded == input |> Map.put("binding", @binding) |> Map.put("version", 2)
  end

  test "the chunk body limit is exactly 270_336 bytes", %{config: config} do
    response = Ziggy.HTTP.call(post("/agent/v1/artifact_chunk", padded(@limit)), config)
    assert response.status == 200
    assert_received {:authority, "ziggy.agent_artifact_chunk", _}

    response = Ziggy.HTTP.call(post("/agent/v1/artifact_chunk", padded(@limit + 1)), config)
    assert response.status == 413
    assert Jason.decode!(response.resp_body) == %{"error" => "request_too_large"}
    refute_received {:authority, _, _}
  end

  test "a guest-supplied binding is refused before Marshall", %{config: config} do
    body = chunk(16) |> Map.put("binding", @binding) |> Jason.encode!()
    response = Ziggy.HTTP.call(post("/agent/v1/artifact_chunk", body), config)

    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "invalid_request"}
    refute_received {:authority, _, _}
  end

  test "other agent routes keep the 12_288-byte limit", %{config: config} do
    body = Jason.encode!(chunk(16))
    oversized = body <> String.duplicate(" ", 12_289 - byte_size(body))

    for route <- ~w(register heartbeat claim transition) do
      response = Ziggy.HTTP.call(post("/agent/v1/" <> route, oversized), config)
      assert response.status == 413
    end

    refute_received {:authority, _, _}
  end

  test "a query string or a missing binding never reaches the chunk route", %{config: config} do
    body = Jason.encode!(chunk(16))

    response = Ziggy.HTTP.call(post("/agent/v1/artifact_chunk?x=1", body), config)
    assert response.status == 400

    unbound =
      Plug.Test.conn(:post, "http://llm.internal/agent/v1/artifact_chunk", body)
      |> put_req_header("content-type", "application/json")

    assert Ziggy.HTTP.call(unbound, config).status == 403
    refute_received {:authority, _, _}
  end
end
