defmodule Lilly.Transfer.ReceiveRuntimeTest do
  # capture_log observes global Logger traffic and the catalogued effect-failure
  # message is fixed for every emitting module, so counting assertions here are
  # only reliable with exclusive execution.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Transfer.ReceiveRuntime

  test "effect failures expose a closed reason once without publishing receipts" do
    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        state = failure_state()
        assert {:noreply, failed} = fail_effect(state, {:error, :storage_busy})
        assert failed.last_failure == :storage_busy
        assert failed.active == nil and failed.pending == state.pending
        assert failed.retry_at > System.monotonic_time(:millisecond)

        assert {:noreply, repeated} = fail_effect(failed, {:error, :storage_busy})
        assert repeated.pending == state.pending
      end)

    assert output =~ "storage_busy"
    assert length(Regex.scan(~r/Relocation effect failed/, output)) == 1
  end

  test "arbitrary failure payloads and command data never become diagnostics" do
    secret = "synthetic-transfer-private-value"

    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        state = failure_state()
        assert {:noreply, failed} = fail_effect(state, {:error, %{token: secret}})
        assert failed.last_failure == :effect_unconfirmed
        assert {:noreply, _} = fail_effect(failed, {:error, secret})
      end)

    assert output =~ "effect_unconfirmed"
    refute output =~ secret
    refute output =~ "private-command"
    assert length(Regex.scan(~r/Relocation effect failed/, output)) == 1
  end

  test "a successful effect permits a later failure diagnostic without losing receipts" do
    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert {:noreply, failed} = fail_effect(failure_state(), {:error, :storage_busy})
        assert {:noreply, succeeded} = fail_effect(failed, {:ok, "300"})
        assert succeeded.last_failure == nil
        assert map_size(succeeded.pending) == 2
        assert {:noreply, later} = fail_effect(succeeded, {:error, :storage_busy})
        assert later.pending == succeeded.pending
      end)

    assert length(Regex.scan(~r/Relocation effect failed/, output)) == 2
  end

  property "import and cleanup diagnostics preserve receipts and never expose wrapped private payloads" do
    cleanup_reasons = [
      :source_lease_unconfirmed,
      :source_command_unconfirmed,
      :source_exports_unconfirmed,
      :source_execution_unavailable,
      :source_claim_unconfirmed,
      :source_intent_unconfirmed,
      :source_unit_unconfirmed,
      :source_jail_unconfirmed,
      :source_network_unconfirmed,
      :source_fence_unconfirmed,
      :source_tombstone_unconfirmed,
      :source_boot_log_unconfirmed,
      :source_snapshots_unconfirmed,
      :source_disk_delete_unconfirmed,
      :storage_busy
    ]

    import_reasons = [
      :import_claim_unconfirmed,
      :import_tombstone_unconfirmed,
      :import_intent_unconfirmed,
      :import_unit_unconfirmed,
      :import_jail_unconfirmed,
      :import_network_unconfirmed,
      :import_disk_adoption_unconfirmed,
      :import_ownership_unconfirmed,
      :import_adoption_unconfirmed,
      :import_publication_unconfirmed,
      :storage_busy,
      :import_busy
    ]

    stages =
      Enum.map(cleanup_reasons, &{:cleanup, &1}) ++
        Enum.map(import_reasons, &{:import, &1}) ++
        [readiness: :execution_unavailable, readiness: :readiness_timeout]

    check all(
            stage <- member_of(stages),
            bytes <- binary(min_length: 1, max_length: 64),
            wrapped? <- boolean()
          ) do
      # Hegel's check all binds plain variables only, so destructure here.
      {mode, reason} = stage
      secret = "private-cleanup-" <> Base.encode16(bytes)
      failure = if wrapped?, do: {:error, {reason, secret}}, else: {:error, reason}
      expected = if wrapped?, do: :effect_unconfirmed, else: reason

      output =
        ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
          state = %{failure_state() | mode: mode}
          assert {:noreply, failed} = fail_effect(state, failure)
          assert failed.last_failure == expected
          assert failed.pending == state.pending
          assert failed.active == nil
          assert failed.retry_at > System.monotonic_time(:millisecond)
          assert {:noreply, repeated} = fail_effect(failed, failure)
          assert repeated.pending == state.pending
        end)

      assert output =~ Atom.to_string(expected)
      refute output =~ secret
      refute output =~ "private-command"
      assert length(Regex.scan(~r/Relocation effect failed/, output)) == 1
    end
  end

  defp failure_state do
    %{
      mode: :receive,
      active: nil,
      pending: %{retained: :receipt},
      last_failure: nil,
      retry_at: System.monotonic_time(:millisecond)
    }
  end

  test "lease diagnostics preserve renewal and stop only expired work" do
    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        state = waiting_effect()
        ref = state.active.task.ref
        assert {:noreply, ^state} = ReceiveRuntime.handle_info({:lease_expired, ref}, state)
        assert Process.alive?(state.active.task.pid)
        expired = put_in(state.active.deadline, System.monotonic_time(:millisecond) - 1)
        assert {:noreply, stopped} = ReceiveRuntime.handle_info({:lease_expired, ref}, expired)
        refute Process.alive?(state.active.task.pid)
        assert stopped.active == nil
        assert stopped.pending == state.pending
        assert stopped.last_failure == :effect_lease_expired
        assert stopped.retry_at > System.monotonic_time(:millisecond)
        assert {:noreply, ^stopped} = ReceiveRuntime.handle_info({:lease_expired, ref}, stopped)
      end)

    assert output =~ "effect_lease_expired"
    assert length(Regex.scan(~r/Relocation effect failed/, output)) == 1
  end

  test "task exit diagnostics never expose exit payloads or create receipts" do
    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        state = waiting_effect()
        task = state.active.task
        message = {:DOWN, task.ref, :process, task.pid, {:private, "synthetic-exit-secret"}}
        assert {:noreply, stopped} = ReceiveRuntime.handle_info(message, state)
        refute Process.alive?(task.pid)
        assert stopped.active == nil and stopped.pending == state.pending
        assert stopped.last_failure == :effect_task_exited
      end)

    assert output =~ "effect_task_exited"
    refute output =~ "synthetic-exit-secret"
  end

  defp waiting_effect do
    task = Task.async(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    timer = Process.send_after(self(), :unexpected_lease_timeout, 60_000)

    %{
      failure_state()
      | active: %{
          task: task,
          timer: timer,
          deadline: System.monotonic_time(:millisecond) + 60_000
        }
    }
  end

  defp fail_effect(state, failure) do
    ref = make_ref()
    task = %Task{pid: self(), owner: self(), ref: ref, mfa: {__MODULE__, :test, 0}}
    timer = Process.send_after(self(), :unexpected_lease_timeout, 60_000)

    active = %{
      task: task,
      timer: timer,
      command: Map.put(command(System.system_time(:second) + 60), :private, "private-command")
    }

    ReceiveRuntime.handle_info({ref, failure}, %{state | active: active})
  end

  defp command(expires),
    do: %{
      id: Lilly.UUID.generate(),
      descriptor: %{identity: :fixture},
      source_endpoint: %{"address" => "source"},
      expires_at: expires
    }

  test "fresh workers immediately schedule the first leased effect for every mode" do
    for mode <- [:receive, :import, :readiness, :cleanup] do
      Task.async(fn ->
        pool = Lilly.UUID.generate()
        before = System.monotonic_time(:millisecond)

        {:ok, state} =
          ReceiveRuntime.init(
            config: %{pools: [%{id: pool}]},
            mode: mode,
            session: %{},
            owner: self()
          )

        assert_receive :tick
        assert state.retry_at >= before
        assert state.retry_at <= System.monotonic_time(:millisecond)
        ref = make_ref()
        exchange = %Task{pid: self(), owner: self(), ref: ref, mfa: {__MODULE__, :test, 0}}
        # Only the scheduler is under test. The deliberately incomplete native
        # configuration fails inside the effect and cannot touch host resources.
        offered = %{
          id: Lilly.UUID.generate(),
          expires_at: System.system_time(:second) + 60,
          descriptor: %{source: %{pool_id: pool}, destination: %{pool_id: pool}}
        }

        response = %{commands: [offered], acknowledgements: []}

        assert {:noreply, %{active: active}} =
                 ReceiveRuntime.handle_info({ref, {:ok, response}}, %{state | exchange: exchange})

        assert active != nil
        assert active.command.id == offered.id
        assert active.deadline > System.monotonic_time(:millisecond)
        Process.cancel_timer(active.timer)
        assert {:error, _} = Task.await(active.task)
      end)
      |> Task.await()
    end
  end

  test "renewal cannot restart expired authority or extend unchanged expiry after clock rollback" do
    original = command(1200)
    assert {:ok, 200_000} = ReceiveRuntime.lease(original, nil, 1000, 0)
    active = %{command: original, deadline: 200_000}
    assert {:ok, 200_000} = ReceiveRuntime.lease(original, active, 950, 50_000)
    assert {:ok, 250_000} = ReceiveRuntime.lease(command(1300), active, 1050, 0)
    assert {:error, _} = ReceiveRuntime.lease(original, active, 1100, 200_000)
    assert {:error, _} = ReceiveRuntime.lease(command(1199), active, 1000, 0)

    assert {:error, _} =
             ReceiveRuntime.lease(%{original | descriptor: %{identity: :other}}, active, 1000, 0)

    assert {:error, _} = ReceiveRuntime.lease(%{original | source_endpoint: %{}}, active, 1000, 0)
    assert {:error, _} = ReceiveRuntime.lease(command(1301), nil, 1000, 0)
    assert {:error, _} = ReceiveRuntime.lease(command(1000), nil, 1000, 0)
  end

  test "import renewal cannot change the received local filesystem identity" do
    original = Map.put(command(1200), :dataset_guid, "300")
    active = %{command: original, deadline: 200_000}
    assert {:ok, 200_000} = ReceiveRuntime.lease(original, active, 1000, 0)
    assert {:error, _} = ReceiveRuntime.lease(%{original | dataset_guid: "301"}, active, 1000, 0)

    assert {:error, _} =
             ReceiveRuntime.lease(Map.delete(original, :dataset_guid), active, 1000, 0)
  end

  test "readiness renewal keeps its activation operation and generation fixed" do
    original = command(1200) |> Map.delete(:source_endpoint) |> Map.put(:generation, 3)
    active = %{command: original, deadline: 200_000}
    assert {:ok, 200_000} = ReceiveRuntime.lease(original, active, 1000, 0)
    assert {:error, _} = ReceiveRuntime.lease(%{original | generation: 4}, active, 1000, 0)

    assert {:error, _} =
             ReceiveRuntime.lease(%{original | id: Lilly.UUID.generate()}, active, 1000, 0)
  end

  property "renewal never exceeds signed expiry growth or remaining wall validity" do
    check all(
            ttl <- integer(1..300),
            elapsed <- integer(0..299),
            growth <- integer(0..300),
            wall_delta <- integer(-100..300)
          ) do
      original = command(1000 + ttl)
      active = %{command: original, deadline: ttl * 1000}
      renewed = %{original | id: Lilly.UUID.generate(), expires_at: original.expires_at + growth}
      monotonic = elapsed * 1000
      wall = 1000 + wall_delta

      case ReceiveRuntime.lease(renewed, active, wall, monotonic) do
        {:ok, deadline} ->
          assert deadline > monotonic
          assert deadline <= active.deadline + growth * 1000
          assert deadline <= monotonic + (renewed.expires_at - wall) * 1000
          assert deadline <= monotonic + 300_000

        {:error, :receive_lease_unconfirmed} ->
          :ok
      end
    end
  end
end
