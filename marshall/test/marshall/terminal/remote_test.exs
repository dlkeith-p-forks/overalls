defmodule Marshall.Terminal.RemoteTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Terminal.{Directory, PeerBudget, Relay, Remote}

  @fixtures Path.expand("../../fixtures/tls", __DIR__)

  setup tags do
    if tags[:isolated_peer_budget] do
      :ok = Supervisor.terminate_child(Marshall.Supervisor, PeerBudget)

      on_exit(fn ->
        {:ok, _budget} = Supervisor.restart_child(Marshall.Supervisor, PeerBudget)
      end)
    end

    if tags[:hegel_case_sandbox], do: :ok, else: terminal_case_fixture()
  end

  # @cc [owner:ghuntley,label:verification;recovery] terminal-generated-fixture-custody
  # Each generated history MUST own a fresh sandbox, TLS listener and peer processes.
  # Budget restart histories MUST use a case supervisor, preserving production
  # restart intensity while proving a successor budget admits replacement peers.
  @spec terminal_case_fixture(boolean()) :: map()
  defp terminal_case_fixture(isolated_budget \\ false) do
    if Hegel.in_property_case?() do
      isolate_property_case()
      Hegel.on_cleanup(&drain_terminal_notifications/0)
    end

    if isolated_budget do
      Overalls.HegelFixtures.start_fixture!(%{
        id: make_ref(),
        start: {Supervisor, :start_link, [[PeerBudget], [strategy: :one_for_one]]}
      })
    end

    server =
      Overalls.HegelFixtures.start_fixture!(
        {Bandit,
         plug: MarshallWeb.TerminalPeerAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    old_url = Application.get_env(:marshall, :terminal_peer_url)
    old_ca = Application.get_env(:marshall, :terminal_peer_ca)
    Application.put_env(:marshall, :terminal_peer_url, "https://127.0.0.1:#{port}")
    Application.put_env(:marshall, :terminal_peer_ca, Path.join(@fixtures, "ca.pem"))

    restore = fn ->
      Application.put_env(:marshall, :terminal_peer_url, old_url)
      Application.put_env(:marshall, :terminal_peer_ca, old_ca)
    end

    if Hegel.in_property_case?() do
      on_exit(:terminal_peer_environment, restore)
      Hegel.on_cleanup(restore)
    else
      on_exit(restore)
    end

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    lifetime = if Hegel.in_property_case?(), do: :property, else: :test
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id, lifetime)
    {:ok, location} = Directory.lookup(fixture.host.id)

    remote =
      Overalls.HegelFixtures.start_fixture!(%{
        id: Remote,
        start: {Remote, :start, [self(), location]},
        restart: :temporary
      })

    %{remote: remote, fixture: fixture, stream: stream}
  end

  # @cc [owner:ghuntley,label:verification;capacity;recovery] peer-budget-incarnation-live-sockets
  # Budget death MUST retire every admitted real TLS peer owner before fresh
  # pairs acquire successor slots. The synthetic host stream MUST remain alive;
  # this test MUST NOT claim native guest survival or independent-node recovery.
  @tag :hegel
  @tag timeout: 600_000, hegel_case_sandbox: true, isolated_peer_budget: true
  test "budget restart retires live TLS peers and admits exact replacement pairs" do
    # The native runner uses test_cases to bound these real-socket histories.
    Hegel.check(
      fn ->
        count = draw("count", integer(1..3))
        %{fixture: fixture, stream: stream, remote: initial} = terminal_case_fixture(true)
        {:ok, location} = Directory.lookup(fixture.host.id)
        remotes = for _ <- 1..count, do: start_peer(location)
        remotes = if Process.alive?(initial), do: [initial | remotes], else: remotes

        for remote <- remotes, do: healthy_peer(remote, fixture.vm)
        old_sockets = Enum.map(remotes, &:sys.get_state(&1).socket)
        budget = Process.whereis(PeerBudget)
        assert PeerBudget.used(budget) == 2 * length(remotes)
        owners = Map.keys(:sys.get_state(budget).owners)
        monitors = Enum.map(owners, &Process.monitor/1)
        budget_monitor = Process.monitor(budget)
        Process.exit(budget, :kill)
        assert_receive {:DOWN, ^budget_monitor, :process, ^budget, :killed}, 1_000

        for {owner, monitor} <- Enum.zip(owners, monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        successor = await_budget(budget, System.monotonic_time(:millisecond) + 2_000)
        assert is_pid(successor)
        assert successor != budget
        assert PeerBudget.used(successor) == 0

        # Old application frames cannot enter a successor incarnation through
        # sockets whose admitted owners have been retired.
        for socket <- old_sockets do
          assert {:error, _} =
                   OverallsProtocol.WebSocket.Connection.send_frame(socket, {:binary, <<0>>})
        end

        assert Process.alive?(stream)
        assert {:ok, ^location} = Directory.lookup(fixture.host.id)

        replacements = for _ <- 1..count, do: start_peer(location)
        for remote <- replacements, do: healthy_peer(remote, fixture.vm)
        assert PeerBudget.used(successor) == 2 * count
        replacement_owners = Map.keys(:sys.get_state(successor).owners)
        replacement_monitors = Enum.map(replacement_owners, &Process.monitor/1)
        for remote <- replacements, do: GenServer.stop(remote)

        for {owner, monitor} <- Enum.zip(replacement_owners, replacement_monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        assert Process.alive?(stream)
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] peer-tls-shifted-silence
  # Real peer output between heartbeat ticks MUST renew outgoing silence;
  # subsequent silent transport MUST retire the hop within fifteen seconds
  # plus bounded test scheduler allowance. The host stream remains synthetic.
  @tag :hegel
  @tag timeout: 6_000_000, hegel_case_sandbox: true
  test "shifted TLS activity expires without waiting for another heartbeat" do
    # Preserve all three runs of one hundred real fifteen-second histories.
    for _ <- 1..3 do
      Hegel.check(
        fn ->
          offset = draw("offset", integer(500..1500))
          %{fixture: fixture, remote: initial} = terminal_case_fixture()
          stop_initial_peer(initial)
          {:ok, previous_location} = Directory.lookup(fixture.host.id)
          assert :ok = Directory.renew(fixture.host.id, previous_location.nonce)
          {:ok, location} = Directory.lookup(fixture.host.id)
          remote = start_peer(location)
          healthy_peer(remote, fixture.vm)
          [peer] = Map.keys(:sys.get_state(PeerBudget).owners) -- [remote]
          marker = make_ref()
          Process.send_after(self(), {:shifted_activity, marker}, offset)
          assert_receive {:shifted_activity, ^marker}, 2_000
          send(peer, {:terminal_output, <<42>>})
          assert_receive {:terminal_output, <<42>>}, 1_000
          last_seen = :sys.get_state(remote).last_seen
          :ok = :sys.suspend(peer)

          Hegel.on_cleanup(fn ->
            try do
              :sys.resume(peer)
            catch
              :exit, _ -> :ok
            end
          end)

          monitor = Process.monitor(remote)
          Process.send_after(self(), {:renew_location, marker}, 10_000)
          assert_receive {:renew_location, ^marker}, 11_000
          assert :ok = Directory.renew(fixture.host.id, location.nonce)
          remaining = max(0, last_seen + 15_000 - System.monotonic_time(:millisecond))
          assert_receive {:DOWN, ^monitor, :process, ^remote, :normal}, remaining + 250
          elapsed = System.monotonic_time(:millisecond) - last_seen
          assert elapsed >= 15_000
          assert elapsed <= 15_250
          assert_receive {:terminal_closed, %{reason: :stream_unavailable}}, 1_000
          :ok = :sys.resume(peer)
          assert await_peer_release(peer, System.monotonic_time(:millisecond) + 2_000)
          assert PeerBudget.used() == 0
        end,
        test_cases: 100
      )
    end
  end

  @spec drain_terminal_notifications() :: :ok
  defp drain_terminal_notifications do
    receive do
      {:terminal_closed, _} -> drain_terminal_notifications()
    after
      0 -> :ok
    end
  end

  @spec stop_initial_peer(pid()) :: :ok
  defp stop_initial_peer(initial) do
    owners = Map.keys(:sys.get_state(PeerBudget).owners)
    monitors = Enum.map(owners, &Process.monitor/1)
    GenServer.stop(initial)

    for {owner, monitor} <- Enum.zip(owners, monitors),
        do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

    :ok
  end

  @spec await_peer_release(pid(), integer()) :: boolean()
  defp await_peer_release(peer, deadline) do
    cond do
      not Map.has_key?(:sys.get_state(PeerBudget).owners, peer) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          1 -> await_peer_release(peer, deadline)
        end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] incoming-peer-tls-silence
  # Incoming peer activity between liveness ticks MUST renew its silence
  # deadline; fifteen subsequent silent seconds MUST terminate its WebSock
  # application and release its slot, independently of server-process lifetime.
  @tag :hegel
  @tag timeout: 6_000_000, hegel_case_sandbox: true
  test "incoming TLS silence retires the application at its renewed deadline" do
    # Preserve all three runs of one hundred real fifteen-second histories.
    for _ <- 1..3 do
      Hegel.check(
        fn ->
          offset = draw("offset", integer(500..1500))
          %{fixture: fixture, remote: initial} = terminal_case_fixture()
          stop_initial_peer(initial)
          {:ok, location} = Directory.lookup(fixture.host.id)
          assert :ok = Directory.renew(fixture.host.id, location.nonce)
          remote = start_peer(location)
          healthy_peer(remote, fixture.vm)
          [peer] = Map.keys(:sys.get_state(PeerBudget).owners) -- [remote]
          previous = peer_last_seen(peer)
          marker = make_ref()
          Process.send_after(self(), {:incoming_activity, marker}, offset)
          assert_receive {:incoming_activity, ^marker}, 2_000
          channel = :sys.get_state(remote).channel
          send(remote, {:viewer_output_ack, channel, 0, 0})
          _ = :sys.get_state(remote)

          last_seen =
            await_peer_activity(peer, previous, System.monotonic_time(:millisecond) + 1_000)

          assert is_integer(last_seen)
          :erlang.trace(peer, true, [:send, :monotonic_timestamp])
          :ok = :sys.suspend(remote)

          Hegel.on_cleanup(fn ->
            try do
              :sys.resume(remote)
            catch
              :exit, _ -> :ok
            end
          end)

          Process.send_after(self(), {:renew_incoming_location, marker}, 10_000)
          assert_receive {:renew_incoming_location, ^marker}, 11_000
          assert :ok = Directory.renew(fixture.host.id, location.nonce)
          remaining = max(0, last_seen + 15_000 - System.monotonic_time(:millisecond))

          timestamp =
            receive do
              {:trace_ts, ^peer, :send, {:"$gen_cast", {:release, ^peer}}, _budget, timestamp} ->
                timestamp
            after
              remaining + 250 ->
                {_socket, %{connection: connection}} = :sys.get_state(peer)
                renewed_by = connection.websock_state.last_seen - last_seen
                occupied = Map.has_key?(:sys.get_state(PeerBudget).owners, peer)

                flunk(
                  "termination unobserved: state=#{connection.state}, renewed_by_ms=#{renewed_by}, occupied=#{occupied}"
                )
            end

          elapsed = System.convert_time_unit(timestamp, :native, :millisecond) - last_seen
          assert elapsed >= 15_000
          assert elapsed <= 15_250
          assert await_peer_release(peer, System.monotonic_time(:millisecond) + 2_000)
          monitor = Process.monitor(remote)
          :ok = :sys.resume(remote)
          assert_receive {:DOWN, ^monitor, :process, ^remote, :normal}, 2_000
          assert_receive {:terminal_closed, %{reason: :stream_unavailable}}, 1_000
          assert PeerBudget.used() == 0
        end,
        test_cases: 100
      )
    end
  end

  @spec peer_last_seen(pid()) :: integer()
  defp peer_last_seen(peer) do
    {_socket, %{connection: %{websock_state: %{last_seen: last_seen}}}} = :sys.get_state(peer)
    last_seen
  end

  @spec await_peer_activity(pid(), integer(), integer()) :: integer() | nil
  defp await_peer_activity(peer, previous, deadline) do
    current = peer_last_seen(peer)

    cond do
      current > previous ->
        current

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        receive do
        after
          1 -> await_peer_activity(peer, previous, deadline)
        end
    end
  end

  @spec start_peer(Marshall.Terminal.Location.t()) :: pid()
  defp start_peer(location) do
    Overalls.HegelFixtures.start_fixture!(%{
      id: make_ref(),
      start: {Remote, :start, [self(), location]},
      restart: :temporary
    })
  end

  @spec healthy_peer(pid(), Marshall.Compute.VirtualMachine.t()) :: :ok
  defp healthy_peer(remote, vm) do
    send(
      remote,
      {:viewer_attach,
       %{
         caller: self(),
         ref: make_ref(),
         message: %{
           type: :attach,
           vm_id: vm.id,
           placement_id: vm.current_placement_id,
           execution_epoch: vm.execution_epoch,
           guest_session_id: 1,
           mode: :ro,
           cursor: 0,
           cols: 80,
           rows: 24
         }
       }}
    )

    assert_receive {:terminal_attached, %{ok: true, channel: channel, guest_session_id: 1}}, 2_000
    assert :sys.get_state(remote).channel == channel

    :ok
  end

  @spec await_budget(pid(), integer()) :: pid() | nil
  defp await_budget(previous, deadline) do
    current = Process.whereis(PeerBudget)

    cond do
      is_pid(current) and current != previous ->
        current

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        receive do
        after
          1 -> await_budget(previous, deadline)
        end
    end
  end

  test "peer forwarding accepts the PID owner with a separate reply alias", %{
    remote: remote,
    fixture: fixture
  } do
    message = %{
      type: :listing,
      vm_id: fixture.vm.id,
      placement_id: fixture.vm.current_placement_id,
      execution_epoch: fixture.vm.execution_epoch
    }

    assert {:ok, %{type: :listed, sessions: []}} = Relay.control(remote, message)
    refute_receive {:relay_reply, _, _}, 0
  end

  test "foreign ownership is refused through the alias, including after it expires", %{
    remote: remote
  } do
    alias_ref = :erlang.alias()
    request = %{caller: remote, ref: make_ref(), reply_to: alias_ref, message: %{type: :listing}}
    send(remote, {:relay_control, request})
    assert_receive {:relay_reply, _, {:error, :stream_busy}}, 1000
    :erlang.unalias(alias_ref)
    send(remote, {:relay_control, request})
    :sys.get_state(remote)
    refute_receive {:relay_reply, _, _}, 0
  end

  test "peer shutdown reports pending failure through the alias", %{remote: remote} do
    :sys.suspend(remote)
    reply_alias = :erlang.alias()
    reference = make_ref()
    request = %{caller: self(), reply_to: reply_alias, ref: reference, message: %{type: :listing}}
    :sys.replace_state(remote, &%{&1 | pending: request})
    # terminate/2 must use the same response destination as a normal control.
    :ok = GenServer.stop(remote, :normal)
    assert_receive {:relay_reply, ^reference, {:error, :stream_unavailable}}
    :erlang.unalias(reply_alias)
  end
end
