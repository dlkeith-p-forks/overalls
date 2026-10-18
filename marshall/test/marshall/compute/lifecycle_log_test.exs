defmodule Marshall.Compute.LifecycleLogTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.{LifecycleEvent, LifecycleLog}

  test "a committed host mark_unknown event logs without requiring a preexisting action atom" do
    notification = notification("mark_unknown", "running", "unknown")

    assert :ok = LifecycleLog.notify(notification)
  end

  test "atoms loaded by unrelated code grant no diagnostic vocabulary" do
    action = Atom.to_string(:test_only_lifecycle_action)
    state = Atom.to_string(:test_only_lifecycle_state)
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    log =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :action, :next_state]],
        fn -> assert :ok = LifecycleLog.notify(notification(action, "running", state)) end
      )

    assert log =~ "action=unrecognized_action"
    assert log =~ "next_state=unrecognized_state"
    refute log =~ action
    refute log =~ state
  end

  test "workspace source delivery journal labels project to closed atoms" do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    for {action, previous, next} <- [
          {"mark_pending", nil, "pending"},
          {"mark_delivering", "pending", "delivering"},
          {"mark_delivered", "delivering", "delivered"},
          {"mark_failed", "delivering", "failed"}
        ] do
      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:event, :resource_type, :action, :previous_state, :next_state]],
          fn ->
            assert :ok =
                     LifecycleLog.notify(notification("WorkspaceSource", action, previous, next))
          end
        )

      assert log =~ "resource_type=workspace_source"
      assert log =~ "action=" <> action
      assert log =~ "next_state=" <> next
      refute log =~ "unrecognized"
    end
  end

  property "unseen persisted labels cannot crash committed audit notifications", test_cases: 30 do
    check all(
            action <- string(:alphanumeric, min_length: 1, max_length: 32),
            state <- string(:alphanumeric, min_length: 1, max_length: 32),
            test_cases: 30
          ) do
      assert :ok = LifecycleLog.notify(notification(action, "running", state))
    end
  end

  @spec notification(String.t(), String.t(), String.t()) :: Ash.Notifier.Notification.t()
  defp notification(action, previous, next),
    do: notification("Execution", action, previous, next)

  @spec notification(String.t(), String.t(), String.t() | nil, String.t()) ::
          Ash.Notifier.Notification.t()
  defp notification(resource_type, action, previous, next) do
    event = %LifecycleEvent{
      event_id: Ash.UUID.generate(),
      resource_type: resource_type,
      resource_id: Ash.UUID.generate(),
      action: action,
      previous_state: previous,
      next_state: next
    }

    %Ash.Notifier.Notification{action: %{name: :record}, data: event}
  end
end
