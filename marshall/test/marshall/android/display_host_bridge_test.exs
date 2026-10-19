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

  test "composes host frames, viewer delivery, and controller input" do
    parent = self()
    host = spawn(fn -> host_loop(parent) end)
    {:ok, relay} = DisplayRelay.start_link(4)
    {:ok, bridge} = DisplayHostBridge.start_link(host, relay, 4)
    assert :ok = DisplayRelay.attach(relay, self(), :controller)
    assert :ok = DisplayRelay.attach(relay, self(), :viewer)

    send(bridge, {:android_display_frame, 4, 1, <<"rfb-frame">>})
    assert_receive {:android_display_frame, 4, 1, <<"rfb-frame">>}

    DisplayHostBridge.input(bridge, self(), <<"key">>)
    assert_receive {:host_input, 4, <<"key">>}
    assert_receive {:android_display_input_accepted, 4, <<"key">>}
  end

  test "host stream loss tears down the composed bridge and closes its channel" do
    parent = self()
    host = spawn(fn -> host_loop(parent) end)
    {:ok, relay} = DisplayRelay.start_link(5)

    {:ok, bridge} =
      DisplayHostBridge.start_link(host, relay, 5, %{
        type: :android_display_open,
        channel: 17,
        generation: 5,
        ticket: "ticket",
        mode: :viewer
      })

    ref = Process.monitor(bridge)
    send(host, :stop)
    assert_receive {:DOWN, ^ref, :process, ^bridge, :normal}, 500
    assert_receive {:host_close, 17}
  end

  defp host_loop(parent) do
    receive do
      {:relay_control, request} ->
        Marshall.Terminal.Relay.reply(request, {:ok, %{ok: true, channel: 17}})
        host_loop(parent)

      {:android_display_input, generation, _viewer, bytes} ->
        send(parent, {:host_input, generation, bytes})
        host_loop(parent)

      {:relay_dispatch, %{type: :android_display_close, channel: channel}} ->
        send(parent, {:host_close, channel})
        host_loop(parent)

      {:android_display_frame, generation, sequence, bytes} ->
        send(parent, {:android_display_frame, generation, sequence, bytes})
        host_loop(parent)

      :stop ->
        :ok
    end
  end
end
