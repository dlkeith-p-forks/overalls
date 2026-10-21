defmodule Ziggy.AttachmentTransferTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  defmodule Authority do
    use GenServer
    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:request, operation, body, _timeout}, _from, owner) do
      send(owner, {:authority, operation, body})
      {:reply, {:ok, %{"id" => "metadata-only"}}, owner}
    end
  end

  @id "11111111-1111-4111-8111-111111111111"
  @spec request(String.t(), map()) :: Plug.Conn.t()
  defp request(route, body) do
    binding = %{"host_id" => @id, "vm_id" => @id, "placement_id" => @id, "execution_epoch" => 1}

    Plug.Test.conn(:post, "http://llm.internal/agent/v1/" <> route, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "x-overalls-binding",
      Base.url_encode64(Jason.encode!(binding), padding: false)
    )
  end

  test "one full chunk uses the trusted binding and a metadata-only response" do
    authority = start_supervised!({Authority, self()})
    config = %{host_id: @id, control: %{client: authority}}

    body = %{
      "executor_id" => @id,
      "fence_epoch" => 1,
      "command_id" => @id,
      "transfer" => %{
        "phase" => "chunk",
        "attachment_id" => @id,
        "offset" => 0,
        "content_base64" => Base.encode64(:binary.copy(<<7>>, 262_144))
      }
    }

    response = Ziggy.HTTP.call(request("attachment/transfer", body), config)
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"id" => "metadata-only"}
    assert_receive {:authority, "ziggy.agent_attachment_transfer", forwarded}
    assert forwarded["binding"]["host_id"] == @id
    assert forwarded["transfer"] == body["transfer"]

    forged = Map.put(body, "binding", %{"host_id" => @id})
    assert Ziggy.HTTP.call(request("attachment/transfer", forged), config).status == 400
    refute_receive {:authority, _, _}

    assert Ziggy.HTTP.call(request("transition", body), config).status == 413

    assert Ziggy.HTTP.call(
             request("attachment/transfer", %{"padding" => String.duplicate("x", 360_449)}),
             config
           ).status == 413

    refute_receive {:authority, _, _}
  end
end
