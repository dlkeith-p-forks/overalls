defmodule Lilly.Transfer.WorkerDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Lilly.Transfer.{KeyRuntime, SourceRuntime}

  @metadata [:event, :component, :operation, :request_id, :reason]
  @request "00000000-0000-4000-8000-000000000001"
  @other "00000000-0000-4000-8000-000000000002"

  # @cc [owner:ghuntley,label:verification;security] transfer-worker-diagnostic-transitions-tested
  # Repeated worker failures MUST remain quiet until a reason change or recovery,
  # retain receipts, and never expose task result/exit payloads. Distinct effect
  # requests MUST retain their own identities even when reasons are identical.
  for runtime <- [KeyRuntime, SourceRuntime] do
    test "#{inspect(runtime)} reports worker failure and recovery once without payloads" do
      runtime = unquote(runtime)

      output =
        capture_log([metadata: @metadata], fn ->
          state = state()
          assert {:noreply, failed} = result(runtime, state, {:error, "private-worker-payload"})
          assert failed.pending == state.pending

          assert {:noreply, repeated} =
                   result(runtime, failed, {:error, %{token: "private-token"}})

          assert repeated.worker_failure == :unconfirmed
          assert {:noreply, recovered} = result(runtime, repeated, {:ok, state.pending, %{}})
          assert recovered.worker_failure == nil
          assert {:noreply, _} = result(runtime, recovered, {:ok, state.pending, %{}})
        end)

      assert length(Regex.scan(~r/Transfer worker unavailable/, output)) == 1
      assert length(Regex.scan(~r/Transfer worker recovered/, output)) == 1
      refute output =~ "private-worker-payload"
      refute output =~ "private-token"
    end

    test "#{inspect(runtime)} correlates separate effect failures and preserves deduplication" do
      runtime = unquote(runtime)

      output =
        capture_log([metadata: @metadata], fn ->
          state = state()

          failures = %{
            @request => :source_request_unconfirmed,
            @other => :source_request_unconfirmed
          }

          assert {:noreply, failed} = result(runtime, state, {:ok, state.pending, failures})
          assert failed.pending == state.pending
          assert {:noreply, _} = result(runtime, failed, {:ok, state.pending, failures})
        end)

      assert output =~ "request_id=#{@request}"
      assert output =~ "request_id=#{@other}"
      assert output =~ "operation=prepare"
      assert length(Regex.scan(~r/Relocation effect failed/, output)) == 2
    end

    test "#{inspect(runtime)} task exits report fixed reasons without discarding receipts" do
      runtime = unquote(runtime)

      output =
        capture_log([metadata: @metadata], fn ->
          state = state()
          task = task()
          message = {:DOWN, task.ref, :process, self(), {:private, "private-exit"}}
          assert {:noreply, failed} = runtime.handle_info(message, %{state | task: task})
          assert failed.pending == state.pending
          assert failed.worker_failure == :effect_task_exited
        end)

      assert output =~ "reason=effect_task_exited"
      refute output =~ "private-exit"
    end
  end

  test "clone worker task loss and recovery preserve the offered work and receipts" do
    output =
      capture_log([metadata: @metadata], fn ->
        state = %{
          mode: :copy,
          task: task(),
          pending: %{retained: :receipt},
          offered: MapSet.new(),
          failures: %{}
        }

        message = {:DOWN, state.task.ref, :process, self(), {:private, "private-clone-exit"}}
        assert {:noreply, failed} = Lilly.Clone.Runtime.handle_info(message, state)
        assert failed.pending == state.pending
        assert failed.worker_failure == :effect_task_exited
        task = task()
        response = {:ok, state.pending, state.offered, false, []}

        assert {:noreply, recovered} =
                 Lilly.Clone.Runtime.handle_info({task.ref, response}, %{failed | task: task})

        assert recovered.worker_failure == nil
        assert recovered.pending == state.pending
      end)

    assert output =~ "component=clone"
    assert output =~ "operation=copy"
    assert length(Regex.scan(~r/Transfer worker unavailable/, output)) == 1
    assert length(Regex.scan(~r/Transfer worker recovered/, output)) == 1
    refute output =~ "private-clone-exit"
  end

  @spec state() :: map()
  defp state,
    do: %{mode: :prepare, task: nil, pending: %{retained: :receipt}, effect_failures: %{}}

  @spec task() :: Task.t()
  defp task, do: %Task{pid: self(), owner: self(), ref: make_ref(), mfa: {__MODULE__, :test, 0}}

  @spec result(module(), map(), term()) :: {:noreply, map()}
  defp result(runtime, state, result) do
    task = task()
    runtime.handle_info({task.ref, result}, %{state | task: task})
  end
end
