defmodule Marshall.Android.DisplayRelayTest do
  use ExUnit.Case, async: true
  alias Marshall.Android.DisplayRelay

  test "allows viewers, fences one controller and sequences frames" do
    {:ok, relay} = DisplayRelay.start_link(3)
    assert :ok = DisplayRelay.attach(relay, self(), :viewer)
    controller = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = DisplayRelay.attach(relay, controller, :controller)
    assert {:error, :controller_busy} = DisplayRelay.attach(relay, self(), :controller)
    assert :ok = DisplayRelay.frame(relay, 3, <<1>>)
    assert_receive {:android_display_frame, 3, 1, <<1>>}
    assert {:error, :stale_generation} = DisplayRelay.frame(relay, 2, <<1>>)
    Process.exit(controller, :kill)
  end

  test "only controller input is accepted" do
    {:ok, relay} = DisplayRelay.start_link(4)
    assert :ok = DisplayRelay.attach(relay, self(), :controller)
    assert :ok = DisplayRelay.input(relay, self(), 4, <<7>>)
    assert_receive {:android_display_input_accepted, 4, <<7>>}
    assert {:error, :input_denied} = DisplayRelay.input(relay, spawn(fn -> Process.sleep(:infinity) end), 4, <<7>>)
  end
end
