defmodule Lilly.VM.FakeExecutorPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.Test.DurableFakeExecutor, as: FakeExecutor

  # @cc [owner:ghuntley,label:verification;recovery] fake-observation-command-causality
  # Generated fake observations MUST refer to an accepted command incarnation;
  # unseen stop/delete revisions MUST preserve the persisted unit and attempts.
  @tag :hegel
  test "fake physical evidence follows accepted command incarnations" do
    check all(
            actions <-
              list_of(
                member_of([:replay, :stop, :delete, :advance, :unseen_stop, :unseen_delete]),
                min_length: 1,
                max_length: 12
              ),
            test_cases: 20
          ) do
      directory =
        Path.join(System.tmp_dir!(), "overalls-fake-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
      on_exit(fn -> File.rm_rf!(directory) end)

      assert {:ok, %{state: :running}} =
               FakeExecutor.reconcile(directory, command(1, :provision), %{})

      path = Path.join(directory, "fake-executor.json")

      initial = %{
        generation: 1,
        status: "running",
        attempts: %{attempt_key(command(1, :provision)) => 1}
      }

      Enum.reduce(Enum.with_index(actions), initial, fn {action, index}, model ->
        next_generation = if action == :advance, do: model.generation + 1, else: model.generation

        kind =
          case action do
            action when action in [:replay, :advance] -> :provision
            action when action in [:stop, :unseen_stop] -> :stop
            :delete -> :delete
            :unseen_delete -> :delete
          end

        sent_generation =
          if action in [:unseen_stop, :unseen_delete],
            do: next_generation + 1,
            else: next_generation

        sent = command(sent_generation, kind)
        assert FakeExecutor.read(path) == model_state(model)

        result =
          if rem(index, 2) == 0 do
            Task.async(fn -> FakeExecutor.reconcile(directory, sent, %{}) end) |> Task.await()
          else
            FakeExecutor.reconcile(directory, sent, %{})
          end

        assert {:ok, observation} = result
        after_state = FakeExecutor.read(path)

        {expected_observation, next_model} =
          case action do
            :advance ->
              {:running,
               %{
                 generation: next_generation,
                 status: "running",
                 attempts: Map.put(model.attempts, attempt_key(sent), 1)
               }}

            :replay when model.status == "running" ->
              {:running, model}

            :replay ->
              {:failed, model}

            :stop when model.status in ["running", "stopped"] ->
              {:stopped, %{model | status: "stopped"}}

            :delete ->
              {:deleted, %{model | status: "deleted"}}

            _ ->
              {:unknown, model}
          end

        assert observation.state == expected_observation
        assert observation == expected_facts(expected_observation)
        assert after_state == model_state(next_model)

        if observation.state in [:running, :stopped, :deleted] do
          assert {after_state["epoch"], after_state["generation"]} ==
                   {sent.execution_epoch, sent.generation}

          assert after_state["attempts"][attempt_key(sent)] == 1
          assert after_state["status"] == Atom.to_string(observation.state)
        end

        assert Enum.all?(after_state["attempts"], fn {_key, count} -> count == 1 end)
        next_model
      end)
    end
  end

  @spec attempt_key(OverallsProtocol.Execution.command()) :: String.t()
  defp attempt_key(command),
    do: "#{command.placement_id}:#{command.execution_epoch}:#{command.generation}"

  @spec model_state(%{generation: pos_integer(), status: String.t(), attempts: map()}) :: map()
  defp model_state(model),
    do: %{
      "epoch" => 1,
      "generation" => model.generation,
      "status" => model.status,
      "attempts" => model.attempts
    }

  @spec expected_facts(:running | :stopped | :deleted | :failed | :unknown) ::
          Lilly.VM.Executor.observation()
  defp expected_facts(status),
    do: %{
      state: status,
      compute_empty: status != :running,
      disk_present: status not in [:deleted, :unknown],
      cleanup_complete: status == :deleted,
      reason:
        case status do
          :failed -> :execution_failed
          :unknown -> :unknown
          _ -> :none
        end
    }

  @spec command(pos_integer(), :provision | :stop | :delete) ::
          OverallsProtocol.Execution.command()
  defp command(generation, kind),
    do: %{
      id: Lilly.UUID.generate(),
      vm_id: "33333333-3333-4333-8333-333333333333",
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: "22222222-2222-4222-8222-222222222222",
      execution_epoch: 1,
      host_id: "11111111-1111-4111-8111-111111111111",
      pool_id: "44444444-4444-4444-8444-444444444444",
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: generation,
      kind: kind,
      architecture: :x86_64,
      profile: :standard,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
