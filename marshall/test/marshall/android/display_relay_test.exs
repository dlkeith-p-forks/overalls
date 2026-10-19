defmodule Marshall.Android.DisplayRelayTest do
  use ExUnit.Case, async: true
  alias Marshall.Android.DisplayRelay

  test "allows viewers, fences one controller and sequences frames" do
    relay = start_supervised!({DisplayRelay, 3})
    assert :ok = DisplayRelay.attach(relay, self(), :viewer)
    controller = start_supervised!({Task, fn -> receive do: (:stop -> :ok) end})
    assert :ok = DisplayRelay.attach(relay, controller, :controller)
    assert {:error, :controller_busy} = DisplayRelay.attach(relay, self(), :controller)
    assert :ok = DisplayRelay.frame(relay, 3, <<1>>)
    assert_receive {:android_display_frame, 3, 1, <<1>>}
    assert {:error, :stale_generation} = DisplayRelay.frame(relay, 2, <<1>>)
    Process.exit(controller, :kill)
  end

  test "only controller input is accepted" do
    relay = start_supervised!({DisplayRelay, 4})
    assert :ok = DisplayRelay.attach(relay, self(), :controller)
    assert :ok = DisplayRelay.input(relay, self(), 4, <<7>>)
    assert_receive {:android_display_input_accepted, 4, <<7>>}
    viewer = start_supervised!({Task, fn -> receive do: (:stop -> :ok) end})
    assert {:error, :input_denied} = DisplayRelay.input(relay, viewer, 4, <<7>>)
  end
end
