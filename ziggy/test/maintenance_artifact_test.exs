defmodule Ziggy.MaintenanceArtifactTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  defmodule Authority do
    use GenServer
    @spec start_link({pid(), map()}) :: GenServer.on_start()
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    @spec init({pid(), map()}) :: {:ok, {pid(), map()}}
    def init(state), do: {:ok, state}
    @impl true
    @spec handle_call(term(), GenServer.from(), {pid(), map()}) ::
            {:reply, term(), {pid(), map()}}
    def handle_call({:request, operation, body, _timeout}, _from, {owner, decision} = state) do
      send(owner, {:authority, operation, body})
      {:reply, {:ok, decision}, state}
    end
  end

  @host "11111111-1111-4111-8111-111111111111"
  @digest String.duplicate("a", 64)

  @spec conn(String.t(), String.t()) :: Plug.Conn.t()
  defp conn(query, host \\ @host) do
    binding = %{
      "host_id" => host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1
    }

    Plug.Test.conn(:get, "http://llm.internal/agent/v1/maintenance/artifacts/#{@digest}?#{query}")
    |> put_req_header(
      "x-overalls-binding",
      Base.url_encode64(Jason.encode!(binding), padding: false)
    )
  end

  test "closed selectors cannot reveal files while authority is unavailable" do
    base = "executor_id=#{@host}&fence_epoch=1&maintenance_id=#{@host}"

    config = %{
      host_id: @host,
      control: nil,
      github_tools: %{
        generation: @digest,
        artifacts: %{@digest => %{path: "/must-never-read", digest: @digest, size: 10}}
      }
    }

    for query <- [
          base,
          "",
          base <> "&executor_id=#{@host}",
          base <> "&path=/etc/passwd",
          String.replace(base, "fence_epoch=1", "fence_epoch=01"),
          String.replace(base, "fence_epoch=1", "fence_epoch=-1"),
          "executor_id=bad&fence_epoch=1&maintenance_id=#{@host}"
        ] do
      response = Ziggy.HTTP.call(conn(query), config)
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"error" => "unavailable"}
      refute response.resp_body =~ "must-never-read"
    end
  end

  test "bootstrap route refuses absent authority and extra query selectors" do
    base = "executor_id=#{@host}&fence_epoch=1&bootstrap_id=#{@host}"

    config = %{
      host_id: @host,
      control: nil,
      bootstrap_release: %{
        artifacts: %{@digest => %{path: "/must-never-read", digest: @digest, size: 10}}
      }
    }

    for query <- [
          base,
          base <> "&maintenance_id=#{@host}",
          "",
          String.replace(base, "fence_epoch=1", "fence_epoch=01")
        ] do
      request = conn(query) |> Map.put(:request_path, "/agent/v1/bootstrap/artifacts/" <> @digest)
      response = Ziggy.HTTP.call(request, config)
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"error" => "unavailable"}
    end
  end

  test "only exact current authority releases packaged bytes" do
    path = Path.join(System.tmp_dir!(), "ziggy-authorized-#{System.unique_integer([:positive])}")
    File.write!(path, "verified-executable")
    on_exit(fn -> File.rm!(path) end)
    size = byte_size("verified-executable")
    base = "executor_id=#{@host}&fence_epoch=1&bootstrap_id=#{@host}"

    for decision <- [
          %{"sha256" => @digest, "bytes" => size},
          %{"sha256" => String.duplicate("b", 64), "bytes" => size},
          %{"sha256" => @digest, "bytes" => size + 1}
        ] do
      authority = start_supervised!({Authority, {self(), decision}}, id: make_ref())

      config = %{
        host_id: @host,
        control: %{client: authority},
        bootstrap_release: %{artifacts: %{@digest => %{path: path, digest: @digest, size: size}}}
      }

      request = conn(base) |> Map.put(:request_path, "/agent/v1/bootstrap/artifacts/" <> @digest)
      response = Ziggy.HTTP.call(request, config)
      assert_receive {:authority, "ziggy.agent_bootstrap_artifact", body}
      assert body["bootstrap_id"] == @host
      assert body["binding"]["host_id"] == @host
      assert body["digest"] == @digest
      assert body["fence_epoch"] == 1

      if decision["sha256"] == @digest and decision["bytes"] == size do
        assert response.status == 200
        assert response.resp_body == "verified-executable"
        assert get_resp_header(response, "cache-control") == ["no-store"]
      else
        assert response.status == 503
        refute response.resp_body =~ "verified-executable"
      end
    end
  end

  test "foreign host binding is denied before inventory lookup" do
    response =
      Ziggy.HTTP.call(conn("", "22222222-2222-4222-8222-222222222222"), %{host_id: @host})

    assert response.status == 403
  end
end
