defmodule Audi.Authority.StreamGuardTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.Authority.StreamGuard

  @binding %{
    host_id: "11111111-1111-4111-8111-111111111111",
    vm_id: "22222222-2222-4222-8222-222222222222",
    placement_id: "33333333-3333-4333-8333-333333333333",
    session_id: "44444444-4444-4444-8444-444444444444",
    execution_epoch: 1
  }

  test "expiry kills even a trapping owner and closes its actual TCP stream" do
    {owner, socket} = stream()
    monitor = Process.monitor(owner)
    guard(owner, 300)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "explicit denial closes the stream immediately" do
    {owner, socket} = stream()
    guard = guard(owner)
    assert :ok = StreamGuard.revoke(guard)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "renewal survives an obsolete expiry message without changing the binding" do
    {owner, socket} = stream()
    started = now() - 100

    guard =
      start_supervised!(
        {StreamGuard, owner: owner, binding: @binding, requested_at: started, ttl: 1000}
      )

    assert :ok = StreamGuard.renew(guard, @binding, now(), 5000)
    send(guard, {:expire, started + 1000})
    _ = :sys.get_state(guard)
    send(owner, {:probe, self()})
    assert_receive :owner_alive
    assert :ok = StreamGuard.revoke(guard)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "killing the guard cannot leave an authorized stream alive" do
    {owner, socket} = stream()
    guard = guard(owner)
    ref = Process.monitor(owner)
    Process.exit(guard, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "a placement change closes the stream and cannot renew it" do
    {owner, socket} = stream()
    guard = guard(owner)

    assert {:error, :binding_changed} =
             StreamGuard.renew(guard, %{@binding | execution_epoch: 2}, now(), 5000)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    assert {:error, :closed} = StreamGuard.renew(guard, @binding, now(), 5000)
  end

  test "a suspended guard cannot postpone the stream deadline" do
    {owner, socket} = stream()
    guard = guard(owner, 300)
    :ok = :sys.suspend(guard)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    :ok = :sys.resume(guard)
  end

  test "owner death releases the guard without waiting for expiry" do
    {owner, _} = stream()
    guard = guard(owner)
    ref = Process.monitor(guard)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^guard, :normal}, 1000
  end

  # @cc [owner:ghuntley,label:verification;security] audi-stream-lease-history
  # Generated grant and guard outcomes MUST close a live stream on refusal,
  # expiry, suspension or guard loss; a stale renewal MUST NOT extend it.
  # The aggregate budget MUST preserve all 100 default histories and their
  # per-action two-second owner-death and one-second socket-closure bounds.

  # Two 300-700 ms expiry waits per history require 60-140 s across the default
  # run, before 700 socket fixtures and the remaining fence assertions.
  @tag timeout: 300_000
  property "a live TCP stream closes for every grant and guard fence" do
    actions =
      draw(
        "actions",
        shuffle([
          :expired_reply,
          :changed_binding,
          :revoke,
          :expiry,
          :suspended_expiry,
          :guard_death,
          :stale_renewal
        ])
      )

    ttl = draw("ttl", member_of([300, 500, 700]))

    for action <- actions do
      {owner, socket} = stream()
      deadline = if action in [:expiry, :suspended_expiry], do: ttl, else: 5000

      guard =
        if action == :expired_reply do
          Overalls.HegelFixtures.start_supervised!(
            {StreamGuard, owner: owner, binding: @binding, requested_at: now() - 1000, ttl: 5000},
            id: make_ref()
          )
        else
          guard(owner, deadline)
        end

      ref = Process.monitor(owner)

      :ok = :gen_tcp.send(socket, "live")
      assert {:ok, "live"} = :gen_tcp.recv(socket, 4, 1000)

      case action do
        :expired_reply ->
          assert {:error, :invalid_grant} =
                   StreamGuard.renew(guard, @binding, now() - 500, 1)

        :changed_binding ->
          assert {:error, :binding_changed} =
                   StreamGuard.renew(guard, %{@binding | execution_epoch: 2}, now(), 1000)

        :revoke ->
          assert :ok = StreamGuard.revoke(guard)

        :expiry ->
          :ok

        :suspended_expiry ->
          :ok = :sys.suspend(guard)

        :guard_death ->
          Process.exit(guard, :kill)

        :stale_renewal ->
          old_deadline = :sys.get_state(guard).lease.expires_at
          assert {:error, :stale} = StreamGuard.renew(guard, @binding, now() - 10_000, 1000)
          assert :sys.get_state(guard).lease.expires_at == old_deadline
          assert Process.alive?(owner)
          :ok = :gen_tcp.send(socket, "again")
          assert {:ok, "again"} = :gen_tcp.recv(socket, 5, 1000)
          assert :ok = StreamGuard.revoke(guard)
      end

      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)

      if action == :suspended_expiry, do: :ok = :sys.resume(guard)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-same-stream-renewal-history
  # Accepted renewal MUST retain the same live owner; stale or obsolete messages
  # MUST NOT change its deadline, and a terminal refusal MUST close its socket.
  property "one TCP owner survives reordered renewals until a terminal fence" do
    actions = draw("actions", shuffle([:stale, :obsolete_expire, :renew_again]))

    for terminal <- [:revoke, :expired_reply, :changed_binding] do
      {owner, socket} = stream()
      initial_started = now()

      guard =
        Overalls.HegelFixtures.start_supervised!(
          {StreamGuard,
           owner: owner, binding: @binding, requested_at: initial_started, ttl: 2000},
          id: make_ref()
        )

      ref = Process.monitor(owner)
      assert_echo(socket, "initial")
      Process.sleep(2)
      first_started = now()
      assert :ok = StreamGuard.renew(guard, @binding, first_started, 2000)
      original_deadline = initial_started + 2000
      assert :sys.get_state(guard).lease.expires_at == first_started + 2000

      latest_started =
        Enum.reduce(actions, first_started, fn action, latest ->
          next =
            case action do
              :stale ->
                deadline = :sys.get_state(guard).lease.expires_at

                assert {:error, :stale} =
                         StreamGuard.renew(guard, @binding, initial_started, 2000)

                assert :sys.get_state(guard).lease.expires_at == deadline
                latest

              :obsolete_expire ->
                deadline = :sys.get_state(guard).lease.expires_at
                send(guard, {:expire, original_deadline})
                assert :sys.get_state(guard).lease.expires_at == deadline
                assert Process.alive?(owner)
                latest

              :renew_again ->
                Process.sleep(2)
                requested = now()
                assert :ok = StreamGuard.renew(guard, @binding, requested, 2000)
                assert :sys.get_state(guard).lease.expires_at == requested + 2000
                requested
            end

          assert_echo(socket, "still-live")
          next
        end)

      case terminal do
        :revoke ->
          assert :ok = StreamGuard.revoke(guard)

        :expired_reply ->
          Process.sleep(2)
          requested = now()
          assert requested > latest_started
          Process.sleep(2)
          assert {:error, :invalid_grant} = StreamGuard.renew(guard, @binding, requested, 1)

        :changed_binding ->
          assert {:error, :binding_changed} =
                   StreamGuard.renew(guard, %{@binding | execution_epoch: 2}, now(), 2000)
      end

      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    end
  end

  @spec assert_echo(port(), binary()) :: :ok
  defp assert_echo(socket, payload) do
    assert :ok = :gen_tcp.send(socket, payload)
    assert {:ok, ^payload} = :gen_tcp.recv(socket, byte_size(payload), 1000)
    :ok
  end

  @spec guard(pid(), pos_integer()) :: pid()
  defp guard(owner, ttl \\ 5000) do
    start_supervised!(
      {StreamGuard, owner: owner, binding: @binding, requested_at: now(), ttl: ttl},
      id: make_ref()
    )
  end

  @spec stream() :: {pid(), port()}
  defp stream do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           Process.flag(:trap_exit, true)
           {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
           {:ok, {_, port}} = :inet.sockname(listener)
           send(parent, {:listener, port})
           {:ok, socket} = :gen_tcp.accept(listener)
           :ok = :gen_tcp.close(listener)
           :ok = :inet.setopts(socket, active: true)
           send(parent, :stream_ready)

           hold_stream(socket)
         end},
        id: make_ref()
      )

    assert_receive {:listener, port}
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    assert_receive :stream_ready
    on_exit(fn -> :gen_tcp.close(socket) end)
    {owner, socket}
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)

  @spec hold_stream(port()) :: no_return()
  defp hold_stream(socket) do
    receive do
      {:probe, caller} ->
        send(caller, :owner_alive)
        hold_stream(socket)

      {:tcp, ^socket, data} ->
        :ok = :gen_tcp.send(socket, data)
        hold_stream(socket)
    end
  end
end
