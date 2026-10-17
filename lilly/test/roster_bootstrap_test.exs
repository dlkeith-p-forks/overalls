defmodule Lilly.RosterBootstrapTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.{Runtime, Store}
  alias Lilly.Execution
  alias Lilly.VM.Actor
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"

  # A booting guest: every observation is retryable, and the boot proof comes
  # from a controllable agent. Native fleet tests exercise the actual Driver.
  defmodule Executor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(_, _, _), do: {:retry, :booting}
    @impl true
    def boot_proof(proof, _command), do: Agent.get(proof, & &1)
  end

  setup %{tmp_dir: directory} = context do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @id, 3)

    command = %{
      id: Lilly.UUID.generate(),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :start,
      architecture: :x86_64,
      profile: Map.get(context, :profile, :customer),
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    {:ok, :stored} = Store.accept(store, command)
    # This test process plays the Runtime: writer of the runtime and intent rows.
    view = :"roster_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, command)
    proof = start_supervised!({Agent, fn -> {:ok, %{pid: 4242, cgroup: directory}} end})

    actor =
      start_supervised!(
        {Actor,
         store: store,
         placement_id: @id,
         owner: self(),
         executor: {Executor, proof},
         view: view,
         watch_executable: nil}
      )

    Actor.reconcile(actor)
    %{actor: actor, proof: proof, store: store, command: command, view: view}
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp roster?(c, address), do: match?({:ok, _}, Runtime.roster_binding(c.view, address))

  test "pending boot gets only roster authority, never general service authority", c do
    eventually(fn -> roster?(c, "10.10.0.2") end)
    assert {:ok, binding} = Runtime.roster_binding(c.view, "10.10.0.2")
    assert binding.operation_id == c.command.id
    assert binding.generation == 1

    assert {:error, :private_service_unavailable} = Runtime.private_binding(c.view, "10.10.0.2")
    assert {:error, :private_service_unavailable} = Runtime.roster_binding(c.view, "10.10.0.3")

    # Definite negative physical evidence revokes at the next observation.
    Agent.update(c.proof, fn _ -> {:error, :readiness_unconfirmed} end)
    Actor.reconcile(c.actor)
    eventually(fn -> not roster?(c, "10.10.0.2") end)
  end

  @tag profile: :inception
  test "Inception personal terminals can obtain a boot-bound account roster", c do
    eventually(fn -> roster?(c, "10.40.0.2") end)
    assert {:ok, binding} = Runtime.roster_binding(c.view, "10.40.0.2")
    assert binding.operation_id == c.command.id
    assert {:error, :private_service_unavailable} = Runtime.private_binding(c.view, "10.40.0.2")
  end

  # A provisioning reconcile waits for guest readiness, which needs the roster.
  defmodule WaitingExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile({_proof, gate}, _command, _history) do
      ref = make_ref()
      send(gate, {:waiting, self(), ref})

      receive do
        {:release, ^ref} -> {:retry, :booting}
      end
    end

    @impl true
    def boot_proof({proof, _gate}, _command), do: Agent.get(proof, & &1)
  end

  # @cc [owner:ghuntley,label:verification;recovery] roster-during-blocked-reconcile
  # Roster bootstrap MUST become available while the actor's reconcile is still
  # blocked waiting for guest readiness: the boot probe supplies the proof.
  test "roster authority appears while a reconcile is blocked waiting for readiness", c do
    stop_supervised!(Actor)

    actor =
      start_supervised!(
        {Actor,
         store: c.store,
         placement_id: @id,
         owner: self(),
         executor: {WaitingExecutor, {c.proof, self()}},
         view: c.view,
         watch_executable: nil}
      )

    Actor.reconcile(actor)
    assert_receive {:waiting, _task, _ref}, 2000
    # The reconcile stays blocked; the per-tick boot probe must still publish.
    eventually(fn -> roster?(c, "10.10.0.2") end)
  end

  test "lock contention is inconclusive and never revokes roster authority", c do
    eventually(fn -> roster?(c, "10.10.0.2") end)
    Agent.update(c.proof, fn _ -> {:error, :execution_unavailable} end)
    Actor.reconcile(c.actor)
    Process.sleep(100)
    assert roster?(c, "10.10.0.2")
  end

  test "disconnection and durable supersession revoke bootstrap immediately", c do
    eventually(fn -> roster?(c, "10.10.0.2") end)
    :ok = Execution.runtime_disconnected(c.view)
    refute roster?(c, "10.10.0.2")
    :ok = Execution.runtime_connected(c.view)
    assert roster?(c, "10.10.0.2")

    newer = %{c.command | id: Lilly.UUID.generate(), generation: 2, kind: :stop}
    {:ok, :stored} = Store.accept(c.store, newer)
    :ok = Execution.intent(c.view, newer)
    refute roster?(c, "10.10.0.2")
  end
end
