defmodule Marshall.Compute.StateMachineTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.{CloneRequest, Operation, ReadinessRequest, ResizeRequest}
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

  @spec change(struct(), atom(), map()) :: Ash.Changeset.t()
  defp change(record, action, args \\ %{}),
    do: Ash.Changeset.for_update(record, action, args, actor: SystemActor.compute())
end
