defmodule Lilly.Transfer.ReceiveProgressTest do
  use ExUnit.Case, async: true
  alias Lilly.Transfer.ReceiveRuntime

  test "only the current leased attempt updates the coalesced transport count" do
    task = %Task{pid: self(), owner: self(), ref: make_ref(), mfa: {__MODULE__, :test, 0}}

    active = %{
      task: task,
      deadline: System.monotonic_time(:millisecond) + 60_000,
      command: %{
        id: Lilly.UUID.generate(),
        descriptor: %{stream: %{source_dataset_guid: "100", to_guid: "200"}}
      },
      attempt_id: Lilly.UUID.generate(),
      attempt_sequence: 1,
      bytes: 0
    }

    state = %{mode: :receive, fenced: false, active: active, pending: %{}}

    assert {:noreply, updated} =
             ReceiveRuntime.handle_info({:lilly_transfer_progress, self(), 42}, state)

    assert updated.active.bytes == 42
    assert updated.active.deadline == state.active.deadline
    assert updated.pending == %{}
    assert {:reply, report, ^updated} = ReceiveRuntime.handle_call(:progress, nil, updated)

    assert report == %{
             request_id: active.command.id,
             attempt_id: active.attempt_id,
             attempt_sequence: 1,
             bytes: 42
           }

    for count <- [41, -1, 9_223_372_036_854_775_808, "43"] do
      assert {:noreply, ^updated} =
               ReceiveRuntime.handle_info({:lilly_transfer_progress, self(), count}, updated)
    end

    for unavailable <- [
          %{updated | fenced: true},
          %{updated | active: nil},
          %{updated | mode: :import},
          put_in(updated.active.deadline, System.monotonic_time(:millisecond) - 1),
          put_in(updated.active.task.pid, nil)
        ] do
      assert {:noreply, ^unavailable} =
               ReceiveRuntime.handle_info({:lilly_transfer_progress, self(), 43}, unavailable)
    end

    inactive = %{updated | active: nil}
    assert {:reply, nil, ^inactive} = ReceiveRuntime.handle_call(:progress, nil, inactive)
  end
end
