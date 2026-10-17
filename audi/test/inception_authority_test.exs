defmodule Audi.Inception.AuthorityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.Inception.Authority

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
            binding: %{session_id: "fixture"},
            host_key: nil,
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
end
