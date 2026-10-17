defmodule Lilly.Control.SessionPoolsTest do
  # @cc [owner:ghuntley,label:verification;protocol] session-pool-identity-strict
  # Lilly MUST accept only Marshall session pool descriptors with exactly id,
  # name, filesystem_id and storage, match them by id, filesystem_id and storage,
  # record exactly that identity in the ownership binding, and refuse a retired
  # `logical_budget_bytes` key (ADR-0159). A session response carrying the
  # retired `terminal_stream` key, or any other unknown key, is refused.
  use ExUnit.Case, async: true
  alias Lilly.Control.Client
  alias Lilly.Host.Pool

  @host "11111111-1111-4111-8111-111111111111"
  @session "22222222-2222-4222-8222-222222222222"
  @pool "33333333-3333-4333-8333-333333333333"
  @storage %{
    backend: :zfs,
    dataset: "tank/lilly",
    zpool_guid: "1",
    dataset_guid: "2"
  }

  @spec pool() :: Pool.t()
  defp pool do
    %Pool{
      id: @pool,
      path: "/tank/lilly",
      filesystem_id: "zfs:1:2",
      host_id: @host,
      storage: @storage
    }
  end

  @spec descriptor() :: %{String.t() => term()}
  defp descriptor do
    %{
      "id" => @pool,
      "name" => "tank",
      "filesystem_id" => "zfs:1:2",
      "storage" => OverallsProtocol.Storage.encode(@storage)
    }
  end

  test "the ownership identity carries exactly id, filesystem_id and storage" do
    assert Pool.session_identity(pool()) == %{
             "id" => @pool,
             "filesystem_id" => "zfs:1:2",
             "storage" => OverallsProtocol.Storage.encode(@storage)
           }
  end

  test "configured pools carry only bound keys and never a retired budget" do
    configured = %{
      "id" => @pool,
      "path" => "/tank/lilly",
      "filesystem_id" => "zfs:1:2",
      "storage" => OverallsProtocol.Storage.encode(@storage),
      "max_iops" => nil,
      "max_iops_source" => nil,
      "template_budget_bytes" => 0,
      "image_io_timeout_ms" => 0
    }

    assert Pool.configuration_keys?(configured)
    refute Pool.configuration_keys?(Map.put(configured, "logical_budget_bytes", 1))
    refute Pool.configuration_keys?(Map.put(configured, "unknown", 1))
    refute Pool.configuration_keys?(Map.put(configured, "standby_per_image", 1))
  end

  test "session pools match by identity, not by name" do
    assert Pool.session_matches?([pool()], [descriptor()])
    assert Pool.session_matches?([pool()], [%{descriptor() | "name" => "renamed"}])
    refute Pool.session_matches?([pool()], [%{descriptor() | "filesystem_id" => "zfs:1:3"}])
    refute Pool.session_matches?([pool()], [%{descriptor() | "id" => @host}])
    refute Pool.session_matches?([pool()], [])
  end

  test "four-key session descriptors are accepted in an exact session response" do
    assert {:ok, session} = open([descriptor()], %{})
    assert session == %{session_id: @session, epoch: 1, pools: [descriptor()]}
  end

  test "a session response with the retired terminal_stream or an unknown key is refused" do
    for extra <- [%{"terminal_stream" => 1}, %{"terminal_stream" => 0}, %{"unknown" => 1}] do
      assert {:error, :invalid_message} = open([descriptor()], extra)
    end
  end

  test "a retired budget, unknown keys and missing identity are rejected" do
    for pools <- [
          [Map.put(descriptor(), "logical_budget_bytes", 107_374_182_400)],
          [Map.put(descriptor(), "logical_budget_bytes", nil)],
          [Map.put(descriptor(), "unknown", 1)],
          [Map.delete(descriptor(), "storage")],
          [Map.delete(descriptor(), "name")]
        ] do
      assert {:error, :invalid_message} = open(pools, %{})
    end
  end

  @spec open([map()], map()) :: {:ok, Client.session()} | {:error, Client.error()}
  defp open(pools, extra) do
    response =
      Map.merge(
        %{
          "version" => 4,
          "host_id" => @host,
          "session_id" => @session,
          "epoch" => 1,
          "pools" => pools,
          "report_interval_ms" => 1000
        },
        extra
      )

    {port, listener} =
      Lilly.Test.ControlStub.start(fn _op, _body -> {:reply, {:ok, response}} end)

    {:ok, client} =
      Client.new("http://127.0.0.1:#{port}", @host, @host <> ":" <> String.duplicate("a", 43),
        allow_insecure_loopback: true,
        protocol_version: 4,
        machine_id: "sha256:" <> String.duplicate("a", 64)
      )

    client = Lilly.Test.ControlStub.connected(client)

    try do
      Client.open(client, @session)
    after
      :gen_tcp.close(listener)
    end
  end
end
