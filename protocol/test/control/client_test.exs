defmodule OverallsProtocol.Control.ClientTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen

  alias OverallsProtocol.Control.{Client, Close, Envelope}
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  defmodule Server do
    @moduledoc "Loopback test server: one scripted connection at a time."

    @spec start(pid(), :accept | :unsupported_version, :inet.port_number()) ::
            {:ok, :inet.port_number()}
    def start(test, mode \\ :accept, port \\ 0) do
      {:ok, listen} =
        :gen_tcp.listen(port, [:binary, :inet, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      generated_case? = Process.get({__MODULE__, :generated_case}, false)

      if generated_case? do
        Hegel.on_cleanup(fn -> :ok = :gen_tcp.close(listen) end)
      end

      {:ok, port} = :inet.port(listen)
      child_id = make_ref()

      ExUnit.Callbacks.start_supervised!(%{
        id: child_id,
        start: {Task, :start_link, [fn -> accept(listen, test, mode) end]},
        restart: :temporary
      })

      if generated_case? do
        Hegel.on_cleanup(fn -> stop_case_child(child_id) end)
      end

      {:ok, port}
    end

    @spec stop_case_child(Supervisor.child_id()) :: :ok
    def stop_case_child(child_id) do
      case ExUnit.Callbacks.stop_supervised(child_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    @spec accept(:gen_tcp.socket(), pid(), :accept | :unsupported_version) :: :ok
    defp accept(listen, test, mode) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          serve(socket, test, mode)
          accept(listen, test, mode)

        {:error, _} ->
          :ok
      end
    end

    @spec serve(:gen_tcp.socket(), pid(), :accept | :unsupported_version) :: :ok
    defp serve(socket, test, mode) do
      with {:ok, head} <- read_head(socket, <<>>) do
        [_ | lines] = String.split(head, "\r\n")

        headers =
          Map.new(lines, fn l ->
            [k, v] = :binary.split(l, ": ")
            {String.downcase(k), v}
          end)

        key = headers["sec-websocket-key"]

        if mode == :unsupported_version or headers["overalls-control"] != "1" do
          send(test, {:upgrade_refused, self()})
          :gen_tcp.send(socket, "HTTP/1.1 426 Upgrade Required\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.close(socket)
        else
          :gen_tcp.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{Handshake.accept(key)}\r\n\r\n"
          )

          send(test, {:server, self(), headers["authorization"] == "Bearer secret-token"})
          send(test, {:server_service, headers["overalls-service"]})
          loop(socket, test, <<>>)
        end
      else
        {:error, :closed} -> :gen_tcp.close(socket)
      end
    end

    defp drain(socket) do
      case :gen_tcp.recv(socket, 0, 2000) do
        {:ok, _} -> drain(socket)
        _ -> :gen_tcp.close(socket)
      end
    end

    @spec read_head(:gen_tcp.socket(), binary()) :: {:ok, binary()} | {:error, :closed}
    defp read_head(socket, buffer) do
      case :binary.split(buffer, "\r\n\r\n") do
        [head, _] ->
          {:ok, head}

        _ ->
          case :gen_tcp.recv(socket, 0, 5000) do
            {:ok, data} -> read_head(socket, buffer <> data)
            {:error, _} -> {:error, :closed}
          end
      end
    end

    defp loop(socket, test, buffer) do
      case Frame.decode(buffer, :server, 1_048_576) do
        {:ok, {:text, text}, rest} ->
          {:ok, message} = Envelope.decode(text)
          send(test, {:received, message})
          loop(socket, test, rest)

        {:ok, {:close, _code, _}, _rest} ->
          :gen_tcp.close(socket)

        {:ok, _other, rest} ->
          loop(socket, test, rest)

        :more ->
          receive do
            {:send, message} ->
              {:ok, data} = Frame.encode({:text, Envelope.encode(message)}, :server, 1_048_576)
              :gen_tcp.send(socket, data)
              loop(socket, test, buffer)

            {:close, code} ->
              # A graceful close, as a real server does: the frame first, then
              # half-close and drain until the client closes its side.
              {:ok, data} = Frame.encode({:close, code, <<>>}, :server, 125)
              :gen_tcp.send(socket, data)
              :gen_tcp.shutdown(socket, :write)
              drain(socket)

            :drop ->
              :gen_tcp.close(socket)
          after
            20 ->
              case :gen_tcp.recv(socket, 0, 20) do
                {:ok, data} -> loop(socket, test, buffer <> data)
                {:error, :timeout} -> loop(socket, test, buffer)
                {:error, _} -> :ok
              end
          end

        {:error, _} ->
          :gen_tcp.close(socket)
      end
    end
  end

  @spec start_client(:inet.port_number(), keyword()) :: pid()
  defp start_client(port, extra \\ []) do
    {:ok, client} =
      Client.start_link(
        [
          url: "http://127.0.0.1:#{port}",
          allow_insecure_loopback: true,
          service: "galileo",
          credential: fn -> {:ok, "secret-token"} end,
          bind: fn -> %{"generation" => 1} end
        ] ++ extra
      )

    client
  end

  @spec welcome(pid()) :: :ok
  defp welcome(server) do
    send(server, {:send, {:welcome, %{conn: "c1", heartbeat_ms: 5000, limits: %{}}}})
    :ok
  end

  test "hello binds the service, a welcome readies requests, and hints reach the owner" do
    {:ok, port} = Server.start(self())
    client = start_client(port)
    assert_receive {:server, server, true}, 2000
    assert_receive {:server_service, "galileo"}, 2000
    assert_receive {:received, {:hello, %{service: "galileo", bind: %{"generation" => 1}}}}, 2000
    refute Client.ready?(client)
    assert Client.request(client, "galileo.renew", %{}) == {:error, :disconnected}
    welcome(server)
    assert_receive {:control, ^client, {:connected, %{conn: "c1"}}}, 2000

    task = Task.async(fn -> Client.request(client, "galileo.renew", %{"lease" => 1}) end)

    assert_receive {:received, {:req, %{id: id, op: "galileo.renew", body: %{"lease" => 1}}}},
                   2000

    send(server, {:send, {:res, %{id: id, result: {:ok, %{"until" => 5}}}}})
    assert Task.await(task) == {:ok, %{"until" => 5}}

    hint_id = "123e4567-e89b-12d3-a456-426614174000"
    send(server, {:send, {:hint, %{kind: "user", id: hint_id}}})
    assert_receive {:control, ^client, {:hint, "user", ^hint_id}}, 2000
    send(server, {:send, :resync})
    assert_receive {:control, ^client, :resync}, 2000
  end

  test "a dropped connection resolves in-flight requests as unproven and reconnects" do
    {:ok, port} = Server.start(self())
    client = start_client(port)
    assert_receive {:server, server, _}, 2000
    welcome(server)
    assert_receive {:control, ^client, {:connected, _}}, 2000
    task = Task.async(fn -> Client.request(client, "galileo.renew", %{}) end)
    assert_receive {:received, {:req, _}}, 2000
    send(server, :drop)
    assert Task.await(task) == {:error, :unproven}
    assert_receive {:control, ^client, {:disconnected, :lost}}, 2000
    # It reconnects on its own and says hello again; nothing is replayed.
    assert_receive {:server, second, _}, 3000
    assert_receive {:received, {:hello, _}}, 2000
    welcome(second)
    assert_receive {:control, ^client, {:connected, _}}, 2000
    refute_receive {:received, {:req, _}}, 200
  end

  test "the welcome's in_flight limit bounds concurrent requests, invalid limits fall back" do
    {:ok, port} = Server.start(self())
    client = start_client(port)
    assert_receive {:server, server, _}, 2000

    send(
      server,
      {:send, {:welcome, %{conn: "c1", heartbeat_ms: 5000, limits: %{"in_flight" => 2}}}}
    )

    assert_receive {:control, ^client, {:connected, _}}, 2000

    tasks =
      for n <- 1..2 do
        Task.async(fn -> Client.request(client, "galileo.renew", %{"n" => n}) end)
      end

    assert_receive {:received, {:req, %{id: first}}}, 2000
    assert_receive {:received, {:req, %{id: second}}}, 2000
    assert Client.request(client, "galileo.renew", %{}) == {:error, :busy}

    for id <- [first, second] do
      send(server, {:send, {:res, %{id: id, result: {:ok, %{}}}}})
    end

    assert Enum.map(tasks, &Task.await/1) == [ok: %{}, ok: %{}]

    send(server, :drop)
    assert_receive {:server, again, _}, 3000

    send(
      again,
      {:send, {:welcome, %{conn: "c2", heartbeat_ms: 5000, limits: %{"in_flight" => 0}}}}
    )

    assert_receive {:control, ^client, {:connected, %{conn: "c2"}}}, 2000

    tasks =
      for n <- 1..8 do
        Task.async(fn -> Client.request(client, "galileo.renew", %{"n" => n}) end)
      end

    for _ <- 1..8 do
      assert_receive({:received, {:req, _}}, 2000)
    end

    assert Client.request(client, "galileo.renew", %{}) == {:error, :busy}
    send(again, :drop)
    assert Enum.all?(tasks, &(Task.await(&1) == {:error, :unproven}))
  end

  test "a hanging connect never blocks requests, status or readiness" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, :inet, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    test = self()

    # Accepts the TCP connection and never answers the upgrade.
    start_supervised!(%{
      id: make_ref(),
      start:
        {Task, :start_link,
         [
           fn ->
             {:ok, socket} = :gen_tcp.accept(listener)
             send(test, :accepted)

             receive do
               :stop -> :gen_tcp.close(socket)
             end
           end
         ]},
      restart: :temporary
    })

    on_exit(fn -> :gen_tcp.close(listener) end)
    client = start_client(port)
    assert_receive :accepted, 2000
    {elapsed, result} = :timer.tc(fn -> Client.request(client, "galileo.renew", %{}) end)
    assert result == {:error, :disconnected}
    assert elapsed < 500_000
    refute Client.ready?(client)
    assert {:disconnected, _} = Client.status(client)
  end

  test "generated fixtures retire after assertion failure and before replay" do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    previous_children = Supervisor.which_children(supervisor)
    {:links, previous_links} = Process.info(self(), :links)
    reference = make_ref()

    result =
      Hegel.run(
        fn ->
          register_case_cleanup()
          start_supervised!(Task.Supervisor)
          {:ok, _port} = Server.start(self())
          send(self(), {:received, :abandoned_fixture_event})
          send(self(), {:cleanup_case_entered, reference})
          flunk("fixture cleanup negative control")
        end,
        test_cases: 1,
        seed: 20_261_017,
        profile: :ci,
        database: :disabled,
        print_blob: false
      )

    assert %{status: :failed} = result
    assert Supervisor.which_children(supervisor) == previous_children
    {:links, current_links} = Process.info(self(), :links)
    assert MapSet.new(current_links) == MapSet.new(previous_links)
    assert_receive {:cleanup_case_entered, ^reference}
    assert_receive {:cleanup_case_entered, ^reference}
    refute_receive {:received, :abandoned_fixture_event}, 0
  end

  # @cc [owner:ghuntley,label:verification;recovery] control-reconnect-cap-after-loss
  # Repeated refused loopback dials MUST retain a backoff ceiling of four seconds;
  # a returning listener MUST receive a fresh hello and restore ready without replay.
  @tag timeout: 150_000
  property "a returning server is reached within the cap after repeated failed dials",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 3,
    seed: 2_114_116_857 do
    register_case_cleanup()
    failures = draw("failures", integer(4..8))
    {:ok, probe} = :gen_tcp.listen(0, [:binary, :inet, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(probe)
    :ok = :gen_tcp.close(probe)

    client_id = make_ref()
    observer = self()

    client =
      start_supervised!(
        {Client,
         url: "http://127.0.0.1:#{port}",
         allow_insecure_loopback: true,
         service: "galileo",
         credential: fn ->
           attempt_ref = make_ref()
           observer_ref = Process.monitor(observer)
           send(observer, {:dial_attempt, client_id, self(), attempt_ref})

           receive do
             {:release_dial, ^attempt_ref} ->
               Process.demonitor(observer_ref, [:flush])
               {:ok, "secret-token"}

             {:DOWN, ^observer_ref, :process, ^observer, _} ->
               {:error, :observer_stopped}
           after
             5000 ->
               Process.demonitor(observer_ref, [:flush])
               {:error, :gate_timeout}
           end
         end,
         bind: fn -> %{"generation" => 1} end,
         owner: self()},
        id: client_id
      )

    for attempt <- 1..failures do
      assert_receive {:dial_attempt, ^client_id, worker, attempt_ref}, 4500
      opening_ref = :sys.get_state(client).opening
      worker_ref = Process.monitor(worker)
      send(worker, {:release_dial, attempt_ref})
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2000
      state = await_client_state(client, &(&1.opening != opening_ref))
      assert state.phase in [:disconnected, :connecting]
      assert state.last_close == :lost
      assert state.backoff in [2000, 4000]

      if attempt >= 2 do
        assert(state.backoff == 4000)
      end
    end

    {:ok, ^port} = Server.start(self(), :accept, port)
    restored_at = System.monotonic_time(:millisecond)
    assert_receive {:dial_attempt, ^client_id, worker, attempt_ref}, 4500
    send(worker, {:release_dial, attempt_ref})
    assert_receive {:server, server, _}, 2000
    assert_receive {:received, {:hello, _}}, 2000
    welcome(server)
    assert_receive {:control, ^client, {:connected, _}}, 2000
    assert System.monotonic_time(:millisecond) - restored_at <= 4500
    assert Client.ready?(client)
    refute_receive {:received, {:req, _}}, 50
    :ok = stop_supervised(client_id)
  end

  # Observing a peer write or worker exit does not prove that the client has
  # processed the asynchronous result. Wait for that owned state transition.
  @spec await_client_state(GenServer.server(), (map() -> boolean())) :: map()
  defp await_client_state(client, predicate) do
    await_client_state(client, predicate, System.monotonic_time(:millisecond) + 2000)
  end

  @spec await_client_state(GenServer.server(), (map() -> boolean()), integer()) :: map()
  defp await_client_state(client, predicate, deadline) do
    state = :sys.get_state(client)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("client did not process the owned opening result before the deadline")

      true ->
        receive do
        after
          1 -> await_client_state(client, predicate, deadline)
        end
    end
  end

  test "close codes are reported to the owner by reason" do
    {:ok, port} = Server.start(self())
    client = start_client(port)
    assert_receive {:server, server, _}, 2000
    welcome(server)
    assert_receive {:control, ^client, {:connected, _}}, 2000
    send(server, {:close, Close.code(:fenced)})
    assert_receive {:control, ^client, {:disconnected, :fenced}}, 2000
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-pending-batch-correlation-and-retirement
  # Real peer-observed requests MUST correlate by their wire IDs, ignore unknown
  # and duplicate responses, and refuse a ninth request when welcome omits its
  # capacity limit and the default is eight. A connection
  # loss MUST resolve every pending caller as unproven without replay; deadlines
  # MUST release capacity and late responses MUST NOT settle successor work. New work
  # on the replacement connection MUST complete independently.
  @tag timeout: 120_000
  property "pending batches correlate exactly and retire without replay",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 2,
    seed: 460_896_662 do
    register_case_cleanup()
    task_supervisor = start_supervised!(Task.Supervisor)

    (
      count = draw("count", member_of([1, 7, 8]))
      mode = draw("mode", member_of([:answered, :dropped, :timed_out]))

      fixed =
        for count <- [1, 7, 8], mode <- [:answered, :dropped, :timed_out] do
          {count, mode}
        end

      for {count, mode} <- fixed ++ [{count, mode}] do
        pending_batch(task_supervisor, count, mode)
      end
    )
  end

  @spec pending_batch(pid(), 1 | 7 | 8, :answered | :dropped | :timed_out) :: :ok
  defp pending_batch(task_supervisor, count, mode) do
    {:ok, port} = Server.start(self())
    child_id = make_ref()

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client,
           url: "http://127.0.0.1:#{port}",
           allow_insecure_loopback: true,
           service: "galileo",
           credential: fn -> {:ok, "secret-token"} end,
           bind: fn -> %{"generation" => 1} end,
           owner: self()},
          id: child_id
        )
      )

    assert_receive {:server, server, true}, 2000
    assert_receive {:server_service, "galileo"}, 2000
    assert_receive {:received, {:hello, _}}, 2000
    welcome(server)
    assert_receive {:control, ^client, {:connected, _}}, 2000

    tasks =
      for ordinal <- 1..count do
        task =
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            Client.request(client, "galileo.renew", %{"ordinal" => ordinal})
          end)

        {ordinal, task}
      end

    requests =
      for _ <- 1..count do
        assert_receive {:received,
                        {:req, %{id: id, op: "galileo.renew", body: %{"ordinal" => ordinal}}}},
                       2000

        {id, ordinal}
      end

    assert MapSet.new(Enum.map(requests, &elem(&1, 1))) == MapSet.new(1..count)
    assert MapSet.size(MapSet.new(Enum.map(requests, &elem(&1, 0)))) == count

    if count == 8 do
      assert Client.request(client, "galileo.renew", %{"ordinal" => 999}) == {:error, :busy}
      refute_receive {:received, {:req, _}}, 50
    end

    for unknown <- [0, 9_007_199_254_740_991] do
      send(server, {:send, {:res, %{id: unknown, result: {:ok, %{"ack" => -1}}}}})
    end

    peer_barrier(server, 33)

    for {_ordinal, task} <- tasks do
      ref = task.ref
      refute_receive {^ref, _}, 0
    end

    active_server =
      case mode do
        :answered ->
          for {id, ordinal} <- Enum.reverse(requests) do
            send(server, {:send, {:res, %{id: id, result: {:ok, %{"ack" => ordinal}}}}})
            send(server, {:send, {:res, %{id: id, result: {:ok, %{"ack" => -ordinal}}}}})
          end

          peer_barrier(server, 34)

          for {ordinal, task} <- tasks do
            assert Task.await(task, 2000) == {:ok, %{"ack" => ordinal}}
          end

          server

        :dropped ->
          send(server, :drop)

          for {_ordinal, task} <- tasks do
            assert Task.await(task, 2000) == {:error, :unproven}
          end

          assert_receive {:control, ^client, {:disconnected, :lost}}, 2000
          assert_receive {:server, replacement, true}, 3000
          assert_receive {:server_service, "galileo"}, 2000
          assert_receive {:received, {:hello, _}}, 2000
          welcome(replacement)
          assert_receive {:control, ^client, {:connected, _}}, 2000
          peer_barrier(replacement, 34)
          refute_receive {:received, {:req, _}}, 200
          replacement

        :timed_out ->
          for {_ordinal, task} <- tasks do
            assert Task.await(task, 6000) == {:error, :timeout}
          end

          for {id, ordinal} <- requests do
            send(server, {:send, {:res, %{id: id, result: {:ok, %{"ack" => -ordinal}}}}})
          end

          peer_barrier(server, 34)
          server
      end

    # This sentinel proves released capacity and continued correlation, rather
    # than treating disappearance of old replies as successor progress.
    successor =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Client.request(client, "galileo.renew", %{"ordinal" => 999})
      end)

    assert_receive {:received,
                    {:req, %{id: next_id, op: "galileo.renew", body: %{"ordinal" => 999}}}},
                   2000

    assert next_id not in Enum.map(requests, &elem(&1, 0))

    for {id, ordinal} <- requests do
      send(active_server, {:send, {:res, %{id: id, result: {:ok, %{"ack" => -ordinal}}}}})
    end

    peer_barrier(active_server, 35)
    send(active_server, {:send, {:res, %{id: next_id, result: {:ok, %{"ack" => 999}}}}})
    assert Task.await(successor, 2000) == {:ok, %{"ack" => 999}}
    stop_supervised!(child_id)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] control-version-refusal-retires-client
  # Unsupported-version close MUST settle all pending callers as unproven and
  # MUST NOT reconnect after the former sixty-second retry interval. Disconnected
  # requests MUST remain refused without wire dispatch or hidden redelivery.
  @tag timeout: 200_000
  property "unsupported version retires pending batches without delayed reconnect",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 2,
    seed: 970_731_517 do
    register_case_cleanup()
    task_supervisor = start_supervised!(Task.Supervisor)

    # Retain the actual former production retry interval. This is a bounded
    # transport observation; it does not establish arbitrary future absence.
    (
      count = draw("count", member_of([1, 7, 8]))
      {:ok, port} = Server.start(self())
      child_id = make_ref()

      client =
        start_supervised!(
          Supervisor.child_spec(
            {Client,
             url: "http://127.0.0.1:#{port}",
             allow_insecure_loopback: true,
             service: "galileo",
             credential: fn -> {:ok, "secret-token"} end,
             bind: fn -> %{"generation" => 1} end,
             owner: self()},
            id: child_id
          )
        )

      assert_receive {:server, server, true}, 2000
      assert_receive {:server_service, "galileo"}, 2000
      assert_receive {:received, {:hello, _}}, 2000
      welcome(server)
      assert_receive {:control, ^client, {:connected, _}}, 2000

      tasks =
        for ordinal <- 1..count do
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            Client.request(client, "galileo.renew", %{"ordinal" => ordinal})
          end)
        end

      ordinals =
        for _ <- 1..count do
          assert_receive {:received, {:req, %{body: %{"ordinal" => ordinal}}}}, 2000
          ordinal
        end

      assert MapSet.new(ordinals) == MapSet.new(1..count)
      send(server, {:close, Close.code(:unsupported_version)})

      for task <- tasks do
        assert Task.await(task, 2000) == {:error, :unproven}
      end

      assert_receive {:control, ^client, {:disconnected, :unsupported_version}}, 2000
      assert Client.status(client) == {:disconnected, :unsupported_version}

      assert Client.request(client, "galileo.renew", %{"ordinal" => 999}) ==
               {:error, :disconnected}

      for _ <- 1..count do
        send(client, :connect)
        refute_receive {:server, _, _}, 2000
        assert Client.status(client) == {:disconnected, :unsupported_version}
      end

      refute_receive {:server, _, _}, 61000
      assert Client.status(client) == {:disconnected, :unsupported_version}
      refute_receive {:received, {:req, _}}, 0
      stop_supervised!(child_id)
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] control-upgrade-version-refusal-is-terminal
  # HTTP426 at upgrade MUST keep the client disconnected and MUST NOT retry after
  # sixty seconds or after queued connect messages; no hello or request is sent.
  @tag timeout: 150_000
  property "HTTP426 retires upgrade attempts and queued connects",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 2,
    seed: 1_635_969_163 do
    register_case_cleanup()
    count = draw("count", integer(1..8))
    {:ok, port} = Server.start(self(), :unsupported_version)
    child_id = make_ref()

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client,
           url: "http://127.0.0.1:#{port}",
           allow_insecure_loopback: true,
           service: "galileo",
           credential: fn -> {:ok, "secret-token"} end,
           bind: fn -> %{"generation" => 1} end,
           owner: self()},
          id: child_id
        )
      )

    assert_receive {:upgrade_refused, server}, 2000
    await_client_state(client, &(&1.phase == :stopped))
    assert Client.status(client) == {:disconnected, :unsupported_version}

    for _ <- 1..count do
      send(client, :connect)
      assert Client.status(client) == {:disconnected, :unsupported_version}
    end

    assert Client.request(client, "galileo.renew", %{}) == {:error, :disconnected}
    refute_receive {:upgrade_refused, ^server}, 61000
    refute_receive {:received, _}, 0
    assert Client.status(client) == {:disconnected, :unsupported_version}
    stop_supervised!(child_id)
  end

  # @cc [owner:ghuntley,label:verification;recovery] control-heartbeat-connection-ownership
  # A replacement connection MUST NOT receive a heartbeat from a retired
  # connection's timer. Its own five-second heartbeat MUST still progress.
  @tag timeout: 90000
  property "reconnects retire old heartbeat ownership before replacement traffic",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 2,
    seed: 1_240_772_644 do
    register_case_cleanup()
    drawn = draw("drawn", integer(0..3))

    for reconnects <- [0, 1, 3, drawn] do
      {:ok, port} = Server.start(self())
      child_id = make_ref()

      client =
        start_supervised!(
          Supervisor.child_spec(
            {Client,
             url: "http://127.0.0.1:#{port}",
             allow_insecure_loopback: true,
             service: "galileo",
             credential: fn -> {:ok, "secret-token"} end,
             bind: fn -> %{"generation" => 1} end,
             owner: self()},
            id: child_id
          )
        )

      assert_receive {:server, initial, true}, 2000
      assert_receive {:server_service, "galileo"}, 2000
      assert_receive {:received, {:hello, _}}, 2000
      welcome(initial)
      assert_receive {:control, ^client, {:connected, _}}, 2000

      {server, retired_timers} =
        Enum.reduce(List.duplicate(:drop, reconnects), {initial, []}, fn :drop,
                                                                         {server, retired} ->
          timer = heartbeat_reference(client)
          send(server, :drop)
          assert_receive {:control, ^client, {:disconnected, :lost}}, 2000
          assert_receive {:server, replacement, true}, 3000
          assert_receive {:server_service, "galileo"}, 2000
          assert_receive {:received, {:hello, _}}, 2000
          welcome(replacement)
          assert_receive {:control, ^client, {:connected, _}}, 2000
          {replacement, [timer | retired]}
        end)

      # Re-deliver real retired refs after the replacement is ready. Timer
      # cancellation cannot remove an already queued message. Also include
      # the old untagged shape, without exposing the private callback state.
      for timer <- retired_timers, _ <- 1..2 do
        send(client, {:timeout, timer, :heartbeat})
      end

      send(client, :heartbeat)

      # The peer barrier precedes observation. Allow100ms for the welcome
      # and barrier transit before the connection-owned five-second deadline.
      peer_barrier(server, 71)
      refute_receive {:received, {:ping, _}}, 4900
      assert_receive {:received, {:ping, counter}}, 2000
      send(server, {:send, {:pong, counter}})
      peer_barrier(server, 72)
      assert Client.ready?(client)
      stop_supervised!(child_id)
    end
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-negotiated-capacity-exact-admission
  # Valid advertised1..256 limits MUST admit exactly that many pending callers;
  # missing or invalid limits MUST use eight. One additional request MUST be
  # refused without dispatch, and reconnect MUST apply the replacement limit.
  @tag timeout: 180_000
  property "negotiated capacity admits exact peer inventories and resets on reconnect",
    profile: :ci,
    database: :disabled,
    print_blob: false,
    test_cases: 2,
    seed: 705_726_619 do
    register_case_cleanup()
    task_supervisor = start_supervised!(Task.Supervisor)
    invalid = [0, -1, 257, 9_007_199_254_740_991, nil, true, false, "1", 2.0, [1], %{}]

    (
      limit = draw("limit", integer(1..256))
      invalid_limit = draw("invalid_limit", member_of(invalid))

      fixed =
        [{%{}, 8}] ++
          Enum.map([1, 8, 64, 256], &{%{"in_flight" => &1}, &1}) ++
          Enum.map(invalid, &{%{"in_flight" => &1}, 8})

      for {limits, expected} <-
            fixed ++ [{%{"in_flight" => limit}, limit}, {%{"in_flight" => invalid_limit}, 8}] do
        {:ok, port} = Server.start(self())
        child_id = make_ref()

        client =
          start_supervised!(
            Supervisor.child_spec(
              {Client,
               url: "http://127.0.0.1:#{port}",
               allow_insecure_loopback: true,
               service: "galileo",
               credential: fn -> {:ok, "secret-token"} end,
               bind: fn -> %{"generation" => 1} end,
               owner: self()},
              id: child_id
            )
          )

        assert_receive {:server, server, true}, 2000
        assert_receive {:server_service, "galileo"}, 2000
        assert_receive {:received, {:hello, _}}, 2000

        send(
          server,
          {:send, {:welcome, %{conn: "capacity1", heartbeat_ms: 5000, limits: limits}}}
        )

        assert_receive {:control, ^client, {:connected, %{conn: "capacity1"}}}, 2000
        capacity_inventory(task_supervisor, client, server, expected)

        send(server, :drop)
        assert_receive {:control, ^client, {:disconnected, :lost}}, 2000
        assert_receive {:server, replacement, true}, 3000
        assert_receive {:server_service, "galileo"}, 2000
        assert_receive {:received, {:hello, _}}, 2000

        replacement_limit =
          if expected == 1 do
            256
          else
            1
          end

        send(
          replacement,
          {:send,
           {:welcome,
            %{
              conn: "capacity2",
              heartbeat_ms: 5000,
              limits: %{"in_flight" => replacement_limit}
            }}}
        )

        assert_receive {:control, ^client, {:connected, %{conn: "capacity2"}}}, 2000
        capacity_inventory(task_supervisor, client, replacement, replacement_limit)
        stop_supervised!(child_id)
      end
    )
  end

  @spec capacity_inventory(pid(), pid(), pid(), 1..256) :: :ok
  defp capacity_inventory(task_supervisor, client, server, count) do
    tasks =
      for ordinal <- 1..count do
        {ordinal,
         Task.Supervisor.async_nolink(task_supervisor, fn ->
           Client.request(client, "galileo.renew", %{"ordinal" => ordinal}, 15000)
         end)}
      end

    inventory =
      for _ <- 1..count do
        assert_receive {:received, {:req, %{id: id, body: %{"ordinal" => ordinal}}}}, 2000
        {id, ordinal}
      end

    assert MapSet.new(Enum.map(inventory, &elem(&1, 1))) == MapSet.new(1..count)
    assert MapSet.size(MapSet.new(Enum.map(inventory, &elem(&1, 0)))) == count
    excess_result = Client.request(client, "galileo.renew", %{"ordinal" => 999})

    if excess_result != {:error, :busy} do
      assert_receive {:received, {:req, %{body: %{"ordinal" => 999}}}}, 2000
      flunk("negotiated capacity dispatched an excess wire request")
    end

    peer_barrier(server, 81)
    refute_receive {:received, {:req, _}}, 0

    for {id, ordinal} <- Enum.reverse(inventory) do
      send(server, {:send, {:res, %{id: id, result: {:ok, %{"ack" => ordinal}}}}})
    end

    peer_barrier(server, 82)

    for {ordinal, task} <- tasks do
      assert(Task.await(task, 2000) == {:ok, %{"ack" => ordinal}})
    end

    :ok
  end

  @spec heartbeat_reference(pid()) :: reference()
  defp heartbeat_reference(client) do
    case Map.get(:sys.get_state(client), :heartbeat_timer) do
      timer when is_reference(timer) -> timer
      _ -> flunk("ready client has no owned heartbeat timer")
    end
  end

  @spec peer_barrier(pid(), non_neg_integer()) :: :ok
  defp peer_barrier(server, counter) do
    send(server, {:send, {:ping, counter}})
    assert_receive {:received, {:pong, ^counter}}, 2000
    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] control-property-fixture-cleanup
  # Each generated transport case MUST retire its listeners, supervised children
  # and queued fixture events before another case or replay starts, including
  # assertion failures. Children present before the case MUST remain untouched.
  @spec register_case_cleanup() :: :ok
  defp register_case_cleanup do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    existing_ids =
      supervisor
      |> Supervisor.which_children()
      |> MapSet.new(fn {id, _pid, _type, _modules} -> id end)

    Process.put({Server, :generated_case}, true)

    Hegel.on_cleanup(fn ->
      for {id, _pid, _type, _modules} <- Supervisor.which_children(supervisor),
          not MapSet.member?(existing_ids, id) do
        Server.stop_case_child(id)
      end

      drain_case_messages()
      Process.delete({Server, :generated_case})
      :ok
    end)
  end

  @spec drain_case_messages() :: :ok
  defp drain_case_messages do
    receive do
      {:server, _server, _authorized?} -> drain_case_messages()
      {:server_service, _service} -> drain_case_messages()
      {:received, _envelope} -> drain_case_messages()
      {:control, _client, _event} -> drain_case_messages()
      {:upgrade_refused, _server} -> drain_case_messages()
      {:dial_attempt, _client_id, _worker, _attempt} -> drain_case_messages()
    after
      0 -> :ok
    end
  end
end
