defmodule Audi.HTTP.AuthorityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.HTTP.Authority

  property "a suspended renewer cannot preserve the owner or its guest socket" do
    # Allow a loaded runner to start the guard before the generated lease expires.
    check all(ttl <- integer(1200..1800), max_runs: 5, test_cases: 1) do
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

  defmodule ScriptedControl do
    @moduledoc "A control channel answering renewals from a fixed script."
    use GenServer

    @spec start_link([term()]) :: GenServer.on_start()
    def start_link(script), do: GenServer.start_link(__MODULE__, script)

    @impl true
    def init(script), do: {:ok, script}

    @impl true
    def handle_call({:request, _op, _body, _timeout}, _from, [reply]),
      do: {:reply, reply, [reply]}

    def handle_call({:request, _op, _body, _timeout}, _from, [reply | rest]),
      do: {:reply, reply, rest}
  end

  @host "22222222-2222-4222-8222-222222222222"
  @vm "33333333-3333-4333-8333-333333333333"
  @label "v-demo-33333333333343338333333333333333"

  defp web_binding,
    do: %{
      host_id: @host,
      vm_id: @vm,
      placement_id: @vm,
      session_id: "44444444-4444-4444-8444-444444444444",
      execution_epoch: 1,
      generation: 1,
      label: @label,
      service: :web,
      port: 8080
    }

  defp renewed_grant(ttl) do
    binding = Map.new(web_binding(), fn {key, value} -> {Atom.to_string(key), value} end)

    {:ok,
     %{
       "version" => 1,
       "grant" => %{
         "binding" => Map.put(binding, "service", "web"),
         "ttl" => ttl,
         "user_id" => nil
       }
     }}
  end

  # Starts a guarded owner whose renewals are answered by `script`.
  defp scripted_owner(script, ttl) do
    parent = self()
    {:ok, control} = ScriptedControl.start_link(script)

    {owner, monitor} =
      spawn_monitor(fn ->
        now = System.monotonic_time(:millisecond)

        grant = %{
          binding: web_binding(),
          user_id: nil,
          requested_at: now,
          expires_at: now + ttl,
          ticket:
            "audi_web_stream_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        }

        client = %Audi.Control.Client{
          origin: "https://localhost:1",
          token: "unused",
          role: :gateway,
          host_id: @host,
          control: control
        }

        {:ok, _worker} = Authority.start(client, grant)
        send(parent, {:started, now})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:started, started}, 1000
    {owner, monitor, started}
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-renewal-across-lilly-restart
  # Marshall answers "unavailable" while Lilly reconnects (ADR-0192). Audi MUST
  # keep the stream and retry within the lease, and a later grant with the
  # unchanged binding MUST carry it past its original deadline.
  test "an unavailable renewal during a Lilly restart is retried and the stream survives" do
    ttl = 3000

    {owner, monitor, started} =
      scripted_owner([{:error, "unavailable"}, {:error, "unavailable"}, renewed_grant(ttl)], ttl)

    # Past the original deadline: only a retried, successful renewal keeps the owner.
    Process.sleep(max(started + ttl + 1500 - System.monotonic_time(:millisecond), 0))
    assert Process.alive?(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1000
  end

  # @cc [owner:ghuntley,label:verification;security] audi-renewal-revocation-conclusive
  # A conclusive refusal (sign-out, revoked grant, stopped VM or newer
  # generation all answer unauthorized, forbidden or authentication_required)
  # MUST end the stream at that renewal, well before its lease deadline.
  test "a conclusive renewal refusal ends the stream before its deadline" do
    for refusal <- ["unauthorized", "forbidden", "authentication_required"] do
      ttl = 6000
      {owner, monitor, started} = scripted_owner([{:error, refusal}], ttl)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 4000
      assert System.monotonic_time(:millisecond) < started + ttl
    end
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
