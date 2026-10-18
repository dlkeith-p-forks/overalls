defmodule Marshall.Agents.PromptWakePropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Agents, Compute}
  alias Marshall.Agents.{AuditEvent, Event, Root, Thread, Turn}
  alias Marshall.Compute.{Ledger, Operation, WakeRequest, WakeRequestKey}

  # @cc [owner:ghuntley,label:verification;recovery] prompt-replay-one-turn-and-wake
  # Across synthetic pending/stopped/paused/running observations, retries MUST
  # retain one prompt, event and admission receipt; sleeping states additionally
  # retain one durable prompt wake and audit reference. Changed content MUST
  # leave that inventory unchanged and no prompt request may execute a guest.
  # Every generated case and replay owns a separate SQL sandbox transaction.
  # This property does not establish physical pause or checkpoint correctness.
  property "prompt retries join one wake without duplicating turns or starting a guest",
    test_cases: 16,
    seed: 2_026_101_806 do
    prompt = draw("prompt text", string(:alphanumeric, min_length: 1, max_length: 64))
    retries = draw("identical retries", integer(1..4))

    state =
      draw("current machine observation", member_of([:pending, :stopped, :paused, :running]))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

    try do
      host_fixture()
      actor = user()
      {:ok, vm} = Compute.provision(request(), actor: actor)
      desired = if state == :pending, do: :running, else: state
      Ash.Seed.update!(vm, %{desired_state: desired, observed_state: state})
      [root] = Ledger.read!(Root, vm_id: vm.id)
      [thread] = Ledger.read!(Thread, root_id: root.id)
      key = Ash.UUID.generate()
      input = %{thread_id: thread.id, prompt: prompt, request_key: key}
      operations = Ledger.read!(Operation, vm_id: vm.id)
      assert {:ok, first} = Agents.submit_prompt(input, actor: actor)

      for _ <- 1..retries do
        assert {:ok, replay} = Agents.submit_prompt(input, actor: actor)
        assert replay.turn_id == first.turn_id
      end

      assert [%{id: turn_id, prompt: ^prompt}] = Ledger.read!(Turn, request_key: key)
      assert turn_id == first.turn_id
      assert [%{kind: :prompt, turn_id: ^turn_id}] = Ledger.read!(Event, turn_id: turn_id)

      assert [%{kind: :prompt_admitted}] =
               Ledger.read!(AuditEvent, turn_id: turn_id, kind: :prompt_admitted)

      if state == :running do
        assert Ledger.read!(WakeRequest, vm_id: vm.id) == []
        assert Ledger.read!(AuditEvent, turn_id: turn_id, kind: :wake_requested) == []
      else
        assert [
                 %{
                   id: wake_id,
                   source: :prompt,
                   request_key: wake_key,
                   requested_by_id: requester
                 }
               ] =
                 Ledger.read!(WakeRequest, vm_id: vm.id)

        assert wake_key == "agent:" <> key and requester == actor.id

        assert [%{kind: :wake_requested, target_id: ^wake_id}] =
                 Ledger.read!(AuditEvent, turn_id: turn_id, kind: :wake_requested)

        assert [%{wake_request_id: ^wake_id}] = Ledger.read!(WakeRequestKey, vm_id: vm.id)
      end

      before = inventory(vm.id, turn_id)

      assert {:error, _} =
               Agents.submit_prompt(%{input | prompt: prompt <> "changed"}, actor: actor)

      assert before == inventory(vm.id, turn_id)
      assert operations == Ledger.read!(Operation, vm_id: vm.id)
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
    end
  end

  @spec inventory(String.t(), String.t()) :: %{atom() => [map()]}
  defp inventory(vm_id, turn_id) do
    %{
      turns: Ledger.read!(Turn, id: turn_id),
      events: Ledger.read!(Event, turn_id: turn_id),
      audits: Ledger.read!(AuditEvent, turn_id: turn_id),
      wakes: Ledger.read!(WakeRequest, vm_id: vm_id),
      keys: Ledger.read!(WakeRequestKey, vm_id: vm_id)
    }
  end
end
