defmodule Ziggy.AgentWorkHintTest do
  use ExUnit.Case, async: false

  test "a ziggy_work hint claims once at once without multiplying the poll cadence" do
    test = self()

    request = fn _control, "agent_next", %{} ->
      send(test, {:claim, System.monotonic_time(:millisecond)})
      {:ok, %{"call" => nil}}
    end

    worker = start_supervised!({Ziggy.AgentWorker, config: %{control: %{}}, request: request})
    control = %{control: :unused}

    assert {:noreply, ^control} =
             Ziggy.Control.Link.handle_info(
               {:control, self(), {:hint, "ziggy_work", "123e4567-e89b-42d3-a456-426614174000"}},
               control
             )

    started = System.monotonic_time(:millisecond)
    assert_receive {:claim, hinted}, 500
    assert hinted - started < 500
    assert Process.alive?(worker)

    # The periodic poll keeps one cadence: about one claim per second.
    Process.sleep(3_300)
    claims = for {:claim, _} <- Process.info(self(), :messages) |> elem(1), do: :claim
    # Doubled timers would claim about seven times; one cadence claims three or four.
    assert length(claims) in 2..5
  end
end
