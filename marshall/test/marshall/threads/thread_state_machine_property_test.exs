defmodule Marshall.Threads.ThreadStateMachinePropertyTest do
  # @cc [owner:ghuntley,label:verification;durability] thread-state-machine-model
  # The declared Thread state machine MUST match the reviewed transition model:
  # every state is reachable from pending, archived exits only through reopen,
  # deleting only archives, and random transition sequences against a real row
  # are accepted exactly when the model has the edge. Accepted transitions MUST
  # record one lifecycle event when they change the row and keep the current
  # generation's status equal to the thread; refused transitions MUST change
  # nothing.
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures, only: [user: 0, request: 0]

  alias Marshall.Compute.{Ledger, LifecycleEvent}
  alias Marshall.Threads.{Generation, Thread}

  @states [:pending, :provisioning, :ready, :failed, :deleting, :archived]

  # The reviewed model (ADR-0255). Changing the resource without changing this
  # table is a deliberate test failure.
  @model %{
    begin_provisioning: {[:pending, :provisioning, :failed], :provisioning},
    bind_agent: {[:pending, :provisioning, :failed], :provisioning},
    mark_ready: {[:provisioning], :ready},
    mark_failed: {[:pending, :provisioning, :failed], :failed},
    requeue: {[:pending, :failed], :pending},
    replace_generation: {[:pending, :failed], :pending},
    reopen: {[:archived], :pending},
    mark_deleting: {[:pending, :provisioning, :ready, :failed], :deleting},
    mark_archived: {[:pending, :provisioning, :ready, :failed, :deleting], :archived}
  }

  @failure_reasons [:capacity, :machine_unavailable, :provision_failed, :agent_unavailable]

  @spec edges() :: [{atom(), atom(), atom()}]
  defp edges do
    for transition <- AshStateMachine.Info.state_machine_transitions(Thread),
        from <- List.wrap(transition.from),
        to <- List.wrap(transition.to),
        do: {transition.action, from, to}
  end

  @spec model_edges() :: [{atom(), atom(), atom()}]
  defp model_edges do
    for {action, {froms, to}} <- @model, from <- froms, do: {action, from, to}
  end

  @spec reachable(atom()) :: MapSet.t(atom())
  defp reachable(start), do: walk([start], MapSet.new([start]))

  defp walk([], seen), do: seen

  defp walk([state | rest], seen) do
    fresh =
      for {_, ^state, to} <- edges(), not MapSet.member?(seen, to), uniq: true, do: to

    walk(fresh ++ rest, Enum.reduce(fresh, seen, &MapSet.put(&2, &1)))
  end

  test "the declared graph is exactly the reviewed model" do
    assert MapSet.new(edges()) == MapSet.new(model_edges())
    assert Enum.sort(Thread.transitions()) == Enum.sort(Map.keys(@model))

    assert MapSet.new(AshStateMachine.Info.state_machine_all_states(Thread)) ==
             MapSet.new(@states)
  end

  test "every state is reachable and archival is the only absorbing exit" do
    assert reachable(:pending) == MapSet.new(@states)
    for state <- @states, do: assert(:archived in reachable(state))

    assert for({action, :archived, _} <- edges(), do: action) == [:reopen]
    assert for({_, :deleting, to} <- edges(), uniq: true, do: to) == [:archived]

    for {action, from, :provisioning} <- edges(), from != :provisioning do
      assert action in [:begin_provisioning, :bind_agent]
    end

    for {_, from, :ready} <- edges(), do: assert(from == :provisioning)
  end

  test "no thread action accepts the status attribute" do
    for action <- Ash.Resource.Info.actions(Thread), action.type in [:create, :update] do
      refute :status in (action.accept || []), "#{action.name} accepts :status"
    end
  end

  @tag :hegel_case_sandbox
  property "random transitions follow the model and leave complete evidence" do
    Marshall.DataCase.isolate_property_case()
    owner = user()
    thread = open_thread(owner)

    steps =
      draw(
        "steps",
        list_of(
          tuple({member_of(Map.keys(@model)), member_of(@failure_reasons)}),
          min_length: 1,
          max_length: 18
        )
      )

    Enum.reduce(steps, thread, fn {action, reason}, current ->
      before = reload(current)
      events_before = lifecycle_count(before.id)
      known_events = MapSet.new(Ledger.read!(LifecycleEvent, resource_id: before.id), & &1.id)
      {froms, to} = Map.fetch!(@model, action)

      # An unconfigured transition raises inside the transaction, rolling it back.
      result =
        try do
          Ledger.transaction(
            fn ->
              locked = Ledger.lock_history!(Thread, before.id)
              updated = Ledger.update!(locked, action, arguments(action, reason))

              if action in [:reopen, :replace_generation],
                do: Generation.open_next!(updated)

              updated
            end,
            {:system, nil}
          )
        rescue
          error in Ash.Error.Invalid -> {:error, error}
        end

      after_row = reload(before)

      if before.status in froms do
        assert {:ok, _} = result
        assert after_row.status == to

        if comparable(before) != comparable(after_row) do
          assert lifecycle_count(before.id) == events_before + 1

          [event] = new_lifecycle(before.id, known_events)
          assert event.action == Atom.to_string(action)
          assert event.previous_state == Atom.to_string(before.status)
          assert event.next_state == Atom.to_string(to)
        else
          assert lifecycle_count(before.id) == events_before
        end

        assert [%Generation{status: ^to}] =
                 Ledger.read!(Generation,
                   thread_id: before.id,
                   machine_key: after_row.machine_key
                 )
      else
        assert {:error, _} = result
        assert comparable(after_row) == comparable(before)
        assert lifecycle_count(before.id) == events_before
      end

      after_row
    end)
  end

  @spec arguments(atom(), atom()) :: map()
  defp arguments(:mark_failed, reason), do: %{failure_reason: reason}

  defp arguments(action, _reason) when action in [:reopen, :replace_generation],
    do: %{machine_key: "thread-property:" <> Ash.UUID.generate()}

  defp arguments(:bind_agent, _reason),
    do: %{agent_root_id: Ash.UUID.generate(), agent_thread_id: Ash.UUID.generate()}

  defp arguments(_action, _reason), do: %{}

  @spec open_thread(Marshall.Accounts.User.t()) :: Thread.t()
  defp open_thread(owner) do
    key = Ash.UUID.generate()

    thread =
      Ledger.create!(Thread, :open, %{
        creator_id: owner.id,
        objective: "Property transitions",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: key,
        machine_key: key
      })

    Generation.open!(thread, 1)
    thread
  end

  @spec reload(Thread.t()) :: Thread.t()
  defp reload(thread), do: Ledger.lock_history!(Thread, thread.id) || flunk("thread vanished")

  @spec comparable(Thread.t()) :: map()
  defp comparable(thread),
    do: Map.drop(Map.from_struct(thread), [:updated_at, :__meta__, :__metadata__, :grants])

  @spec lifecycle_count(String.t()) :: non_neg_integer()
  defp lifecycle_count(id), do: length(Ledger.read!(LifecycleEvent, resource_id: id))

  @spec new_lifecycle(String.t(), MapSet.t(String.t())) :: [LifecycleEvent.t()]
  defp new_lifecycle(id, known) do
    LifecycleEvent
    |> Ledger.read!(resource_id: id)
    |> Enum.reject(&MapSet.member?(known, &1.id))
  end
end
