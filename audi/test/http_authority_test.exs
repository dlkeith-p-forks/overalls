defmodule Audi.HTTP.AuthorityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.HTTP.Authority

  property "a suspended renewer cannot preserve the owner or its guest socket" do
    # Allow a loaded runner to start the guard before the generated lease expires.
    check all(ttl <- integer(1200..1800), max_runs: 5) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)
      parent = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
          now = System.monotonic_time(:millisecond)

          grant = %{
            binding: %{
              host_id: "22222222-2222-4222-8222-222222222222",
              vm_id: "33333333-3333-4333-8333-333333333333",
              placement_id: "33333333-3333-4333-8333-333333333333",
              session_id: "44444444-4444-4444-8444-444444444444",
              execution_epoch: 1,
              generation: 1
            },
            user_id: nil,
            requested_at: now,
            expires_at: now + ttl,
            ticket: "unused"
          }

          # The worker is suspended before it may use this deliberately unreachable client.
          {:ok, worker} =
            Authority.start(
              %Audi.Control.Client{
                origin: "https://localhost:1",
                token: "unused",
                role: :gateway
              },
              grant
            )

          true = :erlang.suspend_process(worker)
          send(parent, {:guarded, worker, socket})

          receive do
            :never -> :ok
          end
        end)

      {:ok, peer} = :gen_tcp.accept(listener, 1000)
      assert_receive {:guarded, worker, _}, 1000
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 3000
      assert {:error, :closed} = :gen_tcp.recv(peer, 0, 1000)
      Process.exit(worker, :kill)
      :gen_tcp.close(peer)
      :gen_tcp.close(listener)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-renewal-transport-no-revoke
  # An unreachable control plane (inconclusive) MUST NOT revoke a stream at its
  # first failed renewal; the unchanged lease deadline still ends it.
  test "a failed renewal transport keeps the stream until its lease deadline" do
    parent = self()
    ttl = 3000

    {owner, monitor} =
      spawn_monitor(fn ->
        now = System.monotonic_time(:millisecond)

        grant = %{
          binding: %{
            host_id: "22222222-2222-4222-8222-222222222222",
            vm_id: "33333333-3333-4333-8333-333333333333",
            placement_id: "33333333-3333-4333-8333-333333333333",
            session_id: "44444444-4444-4444-8444-444444444444",
            execution_epoch: 1,
            generation: 1,
            label: "demo"
          },
          user_id: nil,
          requested_at: now,
          expires_at: now + ttl,
          # A well-formed ticket, so renewal reaches the unreachable transport.
          ticket:
            "audi_web_stream_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        }

        {:ok, _worker} =
          Authority.start(
            %Audi.Control.Client{origin: "https://localhost:1", token: "unused", role: :gateway},
            grant
          )

        send(parent, {:started, now})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:started, started}, 1000
    # Past the first renewal attempt (at most one second in), well before expiry.
    Process.sleep(max(started + 2000 - System.monotonic_time(:millisecond), 0))
    assert Process.alive?(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 3000
  end

  test "only transport, non-2xx and late-grant failures are inconclusive" do
    alias Audi.Authority.Renewal

    for reason <- [:transport_error, :http_error, :expired_response],
        do: assert(Renewal.inconclusive?({:error, reason}))

    for reason <- [
          :unauthorized,
          :forbidden,
          :authentication_required,
          :binding_mismatch,
          :invalid_message,
          :message_too_large,
          :invalid_configuration
        ],
        do: refute(Renewal.inconclusive?({:error, reason}))

    refute Renewal.inconclusive?(false)
    refute Renewal.inconclusive?({:ok, %{}})
  end
end
