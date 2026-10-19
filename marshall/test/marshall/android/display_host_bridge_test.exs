defmodule Marshall.Android.DisplayHostBridgeTest do
  use ExUnit.Case, async: true
  alias Marshall.Android.{DisplayHostBridge, DisplayRelay}

  test "forwards current-generation frames and drops stale frames" do
    {:ok, relay} = DisplayRelay.start_link(2)
    assert :ok = DisplayRelay.attach(relay, self(), :viewer)
    {:ok, bridge} = DisplayHostBridge.start_link(self(), relay, 2)
    DisplayHostBridge.frame(bridge, 2, <<1>>)
    assert_receive {:android_display_frame, 2, 1, <<1>>}
    DisplayHostBridge.frame(bridge, 1, <<2>>)
    refute_receive {:android_display_frame, 1, _, _}, 20
  end

  test "forwards controller input to the host stream" do
    {:ok, relay} = DisplayRelay.start_link(2)
    controller = self()
    assert :ok = DisplayRelay.attach(relay, controller, :controller)
    {:ok, bridge} = DisplayHostBridge.start_link(self(), relay, 2)
    DisplayHostBridge.input(bridge, controller, <<7>>)
    assert_receive {:android_display_input, 2, ^controller, <<7>>}
    assert_receive {:android_display_input_accepted, 2, <<7>>}
  end

  test "viewer input is refused before reaching the host stream" do
    {:ok, relay} = DisplayRelay.start_link(2)
    viewer = self()
    assert :ok = DisplayRelay.attach(relay, viewer, :viewer)
    {:ok, bridge} = DisplayHostBridge.start_link(self(), relay, 2)
    DisplayHostBridge.input(bridge, viewer, <<7>>)
    refute_receive {:android_display_input, _, _, _}, 20
  end
end
