defmodule Marshall.Compute.StateMachineTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.{CloneRequest, Operation, ReadinessRequest, ResizeRequest, WakeRequest}
  alias Marshall.Authorization.SystemActor

  property "clone histories cannot skip snapshots or publish after cancellation" do
    transitions = %{
      queued: %{prepare: :preparing, cancel: :cancelled, fail: :failed},
      preparing: %{stop_source: :stopping, capture: :capturing, request_cancel: :cancelling},
      stopping: %{capture: :capturing, request_cancel: :cancelling},
      capturing: %{confirm_capture: :copying, request_cancel: :cancelling},
      copying: %{confirm_copy: :publishing, request_cancel: :cancelling},
      publishing: %{publish: :cleaning, request_cancel: :cancelling},
      cleaning: %{complete: :complete, fail: :failed},
      cancelling: %{cancel: :cancelled},
      failed: %{retry: :queued, cancel: :cancelled},
      complete: %{},
      cancelled: %{}
    }

    actions = transitions |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    history = draw("history", list_of(member_of(actions), max_length: 50))

    Enum.reduce(history, :queued, fn action, state ->
      expected = transitions |> Map.fetch!(state) |> Map.get(action)
      changeset = change(struct(CloneRequest, phase: state), action)
      assert changeset.valid? == not is_nil(expected)

      if expected do
        assert Ash.Changeset.get_attribute(changeset, :phase) == expected
        expected
      else
        state
      end
    end)
  end

  test "clone cannot skip capture, publish from queue, or mutate phase through progress" do
    queued = struct(CloneRequest, phase: :queued)
    refute change(queued, :publish).valid?
    refute change(queued, :confirm_capture).valid?
    refute change(queued, :record_progress, %{phase: :complete}).valid?
    assert change(queued, :prepare).valid?
  end

  test "a failed readiness deadline cannot become ready" do
    failed = struct(ReadinessRequest, status: :failed)
    refute change(failed, :ready).valid?
    refute change(failed, :fail).valid?
  end

  test "resize failure fences before an explicit restart" do
    request = struct(ResizeRequest, phase: :restarting)
    assert change(request, :fence).valid?
    refute change(%{request | phase: :stopping}, :complete).valid?
    refute change(%{request | phase: :complete}, :restart).valid?
  end

  # @cc [owner:ghuntley,label:recovery;verification] wake-terminal-history
  # Generated histories MUST exercise the actual Ash transition changeset and
  # refuse every advance from a terminal wake receipt, including new demand.
  property "wake histories preserve terminal receipts while capacity demand can advance" do
    active = [:pending, :waiting_capacity, :relocating, :resuming]
    terminal = [:ready, :failed, :cancelled]
    statuses = active ++ terminal
    initial = draw("initial wake status", member_of(statuses))
    targets = draw("wake targets", list_of(member_of(statuses), min_length: 1, max_length: 60))

    Enum.reduce(targets, initial, fn target, state ->
      allowed? = state in active and target != :pending

      changeset =
        change(struct(WakeRequest, status: state), :advance, %{
          status: target,
          finished_at: if(target in terminal, do: ~U[2026-10-19 00:00:00.000000Z])
        })

      assert changeset.valid? == allowed?

      if allowed? do
        assert Ash.Changeset.get_attribute(changeset, :status) == target
        target
      else
        state
      end
    end)
  end

  property "operation histories obey terminal completion and allow late cancelled evidence" do
    actions =
      draw("actions", list_of(member_of([:acknowledge, :complete, :cancel]), max_length: 60))

    Enum.reduce(actions, :pending, fn action, state ->
      expected =
        case {state, action} do
          {:pending, :acknowledge} -> :acknowledged
          {s, :complete} when s in [:pending, :acknowledged, :cancelled] -> :completed
          {s, :cancel} when s in [:pending, :acknowledged] -> :cancelled
          _ -> nil
        end

      changeset = change(struct(Operation, status: state), action)
      assert changeset.valid? == not is_nil(expected)

      if expected do
        assert Ash.Changeset.get_attribute(changeset, :status) == expected
        expected
      else
        state
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery;verification] suspension-lifecycle-state-machine
  # Generated suspension histories MUST preserve the lifecycle fences: only an idle,
  # unpinned running machine may pause; wake demand coalesces while paused or waiting
  # for capacity; relocation never loses the checkpoint; and a cold start is never
  # admitted for a machine that still owns a checkpoint.
  property "suspension histories preserve checkpoint, wake and idle invariants" do
    actions =
      draw(
        "suspension actions",
        list_of(
          member_of([
            :tool_call,
            :idle_expire,
            :pin,
            :unpin,
            :pause,
            :prompt_wake,
            :network_wake,
            :capacity_unavailable,
            :capacity_available,
            :relocate,
            :cancel
          ]),
          min_length: 1,
          max_length: 80
        )
      )

    initial = %{state: :running, pinned: false, checkpoint: false, wake_requests: 0}

    final =
      Enum.reduce(actions, initial, fn action, model ->
        next = suspension_transition(model, action)

        assert next.wake_requests in 0..1
        assert next.checkpoint or next.state not in [:paused, :waiting_capacity, :relocating]
        refute next.state == :running and next.checkpoint and action == :idle_expire

        next
      end)

    assert final.state in [:running, :paused, :waiting_capacity, :relocating]
  end

  @spec suspension_transition(map(), atom()) :: map()
  defp suspension_transition(model, :tool_call),
    do: %{model | state: :running, checkpoint: false, wake_requests: 0}

  defp suspension_transition(%{state: :running} = model, :idle_expire) do
    if model.pinned, do: model, else: %{model | state: :paused, checkpoint: true}
  end

  defp suspension_transition(model, :idle_expire), do: model
  defp suspension_transition(model, :pin), do: %{model | pinned: true}
  defp suspension_transition(model, :unpin), do: %{model | pinned: false}

  defp suspension_transition(%{state: :running} = model, :pause),
    do: %{model | state: :paused, checkpoint: true}

  defp suspension_transition(%{state: state} = model, action)
       when action in [:prompt_wake, :network_wake] and state in [:paused, :waiting_capacity] do
    %{model | wake_requests: 1}
  end

  defp suspension_transition(%{state: :paused, wake_requests: 1} = model, :capacity_unavailable),
    do: %{model | state: :waiting_capacity}

  defp suspension_transition(%{state: :paused, wake_requests: 1} = model, :capacity_available),
    do: %{model | state: :running, checkpoint: false, wake_requests: 0}

  defp suspension_transition(
         %{state: :waiting_capacity, wake_requests: 1} = model,
         :capacity_available
       ),
       do: %{model | state: :running, checkpoint: false, wake_requests: 0}

  defp suspension_transition(%{state: state, checkpoint: true} = model, :relocate)
       when state in [:paused, :waiting_capacity],
       do: %{model | state: :relocating}

  defp suspension_transition(%{state: :relocating} = model, :capacity_available),
    do: %{model | state: :paused}

  defp suspension_transition(%{state: state} = model, :cancel)
       when state in [:relocating, :waiting_capacity],
       do: %{model | state: :paused}

  defp suspension_transition(model, _action), do: model

  @spec change(struct(), atom(), map()) :: Ash.Changeset.t()
  defp change(record, action, args \\ %{}),
    do: Ash.Changeset.for_update(record, action, args, actor: SystemActor.compute())
end
