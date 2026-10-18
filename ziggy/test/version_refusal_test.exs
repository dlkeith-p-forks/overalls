defmodule Ziggy.VersionRefusalTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  @id "01234567-89ab-4def-8123-456789abcdef"
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  defmodule RefusingEndpoint do
    @behaviour Plug

    @spec init(pid()) :: pid()
    @impl true
    def init(owner), do: owner

    @spec call(Plug.Conn.t(), pid()) :: Plug.Conn.t()
    @impl true
    def call(conn, owner) do
      send(owner, {:refused_path, conn.request_path})

      body =
        if String.ends_with?(conn.request_path, "/agent_next"),
          do: String.duplicate("x", 530_000),
          else: String.duplicate("x", 20_000)

      Plug.Conn.send_resp(conn, 426, body)
    end
  end

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ziggy-version-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  property "wire 426 stays terminal even when its body exceeds the reply limit", profile: :ci, test_cases: 1 do
    endpoint =
      start_supervised!(
        {Bandit,
         plug: {RefusingEndpoint, self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(endpoint)

    control = %{
      origin: "https://localhost:#{port}",
      token: "fixture-token",
      ca_file: Path.join(@fixtures, "ca.pem"),
      host_id: @id,
      client: :"ziggy_refused_#{System.unique_integer([:positive])}"
    }

    start_supervised!({Ziggy.Control.Link, control})
    # The upgrade itself is refused with 426 and an oversized body.
    assert_receive {:refused_path, "/api/control/v1"}, 3_000
    refused(control.client, 100)

    check all(
            routes <-
              list_of(member_of(["complete", "agent_next", "admit"]),
                min_length: 1,
                max_length: 4
              ),
            max_runs: 8
          ) do
      for route <- routes do
        assert {:error, :unsupported_version} = Ziggy.Control.request(control, route, %{})
      end
    end
  end

  @spec refused(atom(), non_neg_integer()) :: :ok
  defp refused(_client, 0), do: flunk("version refusal never recorded")

  defp refused(client, attempts) do
    if OverallsProtocol.Control.Client.status(client) == {:disconnected, :unsupported_version} do
      :ok
    else
      Process.sleep(20)
      refused(client, attempts - 1)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] version-refusal-stops-retries
  # Generated transient replies MAY retry, but a subsequent 426 MUST leave
  # durable completions unacknowledged and stop automatic control requests.
  test "completion reporter stops after version refusal and retains receipts", c do
    check all(transient_replies <- integer(0..4), max_runs: 8) do
      directory = Path.join(c.directory, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)

      spool =
        start_supervised!(
          Supervisor.child_spec(
            {Ziggy.Spool, directory: directory, max_requests: 1},
            id: {:spool, make_ref()}
          )
        )

      assert :ok = Ziggy.Spool.admit(spool, admission())
      assert :ok = Ziggy.Spool.complete(spool, @id, completion())
      owner = self()

      request = fn _control, route, %{"request_id" => id} ->
        send(owner, {:request, route, id})
        attempt = Process.get(:attempt, 0) + 1
        Process.put(:attempt, attempt)

        if attempt <= transient_replies,
          do: {:error, :authority_unavailable},
          else: Ziggy.Control.socket_result({:error, "unsupported_version"}, route, 16_384, nil)
      end

      reporter =
        start_supervised!(
          Supervisor.child_spec(
            {Ziggy.Reporter, spool: spool, control: %{}, request: request},
            id: {:reporter, make_ref()}
          )
        )

      for attempt <- 1..(transient_replies + 1) do
        assert_receive {:request, "complete", @id}, 1000
        if attempt <= transient_replies, do: send(reporter, :report)
      end

      assert Ziggy.VersionFence.fenced?(:sys.get_state(reporter).fence)

      for _ <- 1..3, do: send(reporter, :report)
      assert Ziggy.VersionFence.fenced?(:sys.get_state(reporter).fence)
      refute_receive {:request, _, _}, 20

      assert [%{"admission" => %{"request_id" => @id}, "completion" => completion}] =
               Ziggy.Spool.pending(spool)

      assert completion == completion()
    end
  end

  property "model poll stops after version refusal" do
    check all(transient_replies <- integer(0..4), max_runs: 8) do
      owner = self()

      request = fn _control, route, _body ->
        send(owner, {:request, route})
        attempt = Process.get(:attempt, 0) + 1
        Process.put(:attempt, attempt)

        if attempt <= transient_replies,
          do: {:error, :authority_unavailable},
          else: Ziggy.Control.socket_result({:error, "unsupported_version"}, route, 16_384, nil)
      end

      worker =
        start_supervised!({Ziggy.AgentWorker, config: %{control: %{}}, request: request})

      for _ <- 1..(transient_replies + 1) do
        send(worker, :poll)
        assert_receive {:request, "agent_next"}, 1000
      end

      assert %{fence: fence, active: active} = :sys.get_state(worker)
      assert Ziggy.VersionFence.fenced?(fence)
      assert active == %{}
      for _ <- 1..3, do: send(worker, :poll)
      assert Ziggy.VersionFence.fenced?(:sys.get_state(worker).fence)
      refute_receive {:request, _}, 20
      stop_supervised!(Ziggy.AgentWorker)
    end
  end

  test "one version refusal preserves every queued completion", c do
    check all(receipts <- integer(1..5), max_runs: 5) do
      directory = Path.join(c.directory, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)

      spool =
        start_supervised!(
          Supervisor.child_spec(
            {Ziggy.Spool, directory: directory, max_requests: receipts},
            id: {:spool, make_ref()}
          )
        )

      ids = Enum.map(1..receipts, &request_id/1)

      for id <- ids do
        assert :ok = Ziggy.Spool.admit(spool, admission(id))
        assert :ok = Ziggy.Spool.complete(spool, id, completion())
      end

      owner = self()

      request = fn _control, _route, %{"request_id" => id} ->
        send(owner, {:request, id})
        {:error, :unsupported_version}
      end

      reporter =
        start_supervised!(
          Supervisor.child_spec(
            {Ziggy.Reporter, spool: spool, control: %{}, request: request},
            id: {:reporter, make_ref()}
          )
        )

      assert_receive {:request, _}, 1000
      assert Ziggy.VersionFence.fenced?(:sys.get_state(reporter).fence)
      for _ <- 1..3, do: send(reporter, :report)
      assert Ziggy.VersionFence.fenced?(:sys.get_state(reporter).fence)
      refute_receive {:request, _}, 20

      retained =
        spool
        |> Ziggy.Spool.pending()
        |> Enum.map(&get_in(&1, ["admission", "request_id"]))

      assert Enum.sort(retained) == Enum.sort(ids)
    end
  end

  @spec request_id(pos_integer()) :: String.t()
  defp request_id(number),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number, 16), 12, "0")

  @spec admission() :: map()
  defp admission, do: admission(@id)

  @spec admission(String.t()) :: map()
  defp admission(id),
    do: %{
      "request_id" => id,
      "host_id" => @id,
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => 1,
      "owner_id" => @id,
      "provider" => "openai",
      "model" => "gpt-test",
      "operation" => "responses",
      "admitted_at" => 1
    }

  @spec completion() :: map()
  defp completion,
    do: %{
      "outcome" => "interrupted",
      "tokens" => %{},
      "completeness" => "unknown",
      "duration_ms" => 0,
      "request_bytes" => 0,
      "response_bytes" => 0
    }

  # @cc [owner:ghuntley,label:verification;recovery] ziggy-version-fence-recovers
  # After a refusal only the backed-off probe may report; once Marshall accepts
  # the version again, reporting resumes and the receipt is acknowledged.
  test "a version fence probes after backoff and recovers when accepted", c do
    directory = Path.join(c.directory, "recovery")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    spool = start_supervised!({Ziggy.Spool, directory: directory, max_requests: 1})
    assert :ok = Ziggy.Spool.admit(spool, admission())
    assert :ok = Ziggy.Spool.complete(spool, @id, completion())
    owner = self()

    request = fn _control, "complete", %{"request_id" => id} ->
      send(owner, {:request, id})
      attempt = Process.get(:attempt, 0) + 1
      Process.put(:attempt, attempt)

      if attempt == 1,
        do: {:error, :unsupported_version},
        else: {:ok, %{"acknowledged" => id}}
    end

    reporter =
      start_supervised!(
        {Ziggy.Reporter, spool: spool, control: %{}, request: request, fence_backoff_ms: 50}
      )

    assert_receive {:request, @id}, 1000
    # A stray poke while fenced sends nothing; the probe does.
    send(reporter, :report)
    assert_receive {:request, @id}, 1000
    refute Ziggy.VersionFence.fenced?(:sys.get_state(reporter).fence)
    assert Ziggy.Spool.pending(spool) == []
  end
end
