defmodule MarshallWeb.LiveObservabilityTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias MarshallWeb.LiveObservability

  setup do
    :ok = LiveObservability.attach()
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :live, :callback],
        fn _event, measurements, metadata, _ ->
          send(test, {:callback, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # @cc [owner:ghuntley,label:verification;observability] live-callback-registry-complete
  # Every Marshall LiveView module MUST have a unique registered label that the
  # reviewed trace vocabulary admits.
  test "every LiveView has a unique label in the reviewed trace vocabulary" do
    {:ok, modules} = :application.get_key(:marshall, :modules)

    live_views =
      Enum.filter(modules, fn module ->
        Code.ensure_loaded?(module) and function_exported?(module, :__live__, 0) and
          module.__live__()[:kind] == :view
      end)

    assert live_views != []
    assert Enum.sort(live_views) == Enum.sort(Map.keys(LiveObservability.views()))

    labels = Map.values(LiveObservability.views())
    assert length(labels) == length(Enum.uniq(labels))
    for label <- labels, do: assert(Overalls.Diagnostics.Schema.enum?(label), "#{label}")
    assert Overalls.Diagnostics.Schema.enum?(LiveObservability.label(Enum))
  end

  test "mount, events and messages each record one closed measurement", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, user()), "/overview")
    assert_measured(:mount)

    render_click(view, "visibility", %{"visible" => true})
    assert_measured(:handle_event)

    send(view.pid, :refresh)
    _ = render(view)
    assert_measured(:handle_info)
  end

  test "wrapped messages keep the exact result and exception" do
    socket = %Phoenix.LiveView.Socket{view: MarshallWeb.OverviewLive}
    keys = Process.get_keys()

    assert {:noreply, ^socket} =
             LiveObservability.handle_info(socket, fn -> {:noreply, socket} end)

    assert_measured(:handle_info)

    assert_raise RuntimeError, "callback failed", fn ->
      LiveObservability.handle_info(socket, fn -> raise "callback failed" end)
    end

    assert_measured(:handle_info)
    assert Process.get_keys() == keys
  end

  test "every callback is admitted before it runs and settled once by outcome" do
    test = self()

    recorder =
      spawn_link(fn ->
        Process.register(self(), Marshall.LiveRecorder)
        send(test, :recorder_ready)
        fake_recorder(test)
      end)

    assert_receive :recorder_ready
    on_exit(fn -> Process.exit(recorder, :kill) end)
    socket = %Phoenix.LiveView.Socket{view: MarshallWeb.OverviewLive}

    assert {:noreply, ^socket} =
             LiveObservability.handle_info(socket, fn ->
               assert_received {:recorder, {:admit, owner, _deadline}, ticket}
               send(test, {:admitted_before_work, owner, ticket})
               {:noreply, socket}
             end)

    assert_received {:admitted_before_work, owner, ticket}
    assert owner == self()
    assert_receive {:recorder, {:complete, ^ticket, :success, duration}, :ok}
    assert is_integer(duration) and duration >= 0

    assert_raise RuntimeError, fn ->
      LiveObservability.handle_info(socket, fn -> raise "callback failed" end)
    end

    assert_receive {:recorder, {:admit, _owner, _deadline}, failed}
    assert_receive {:recorder, {:complete, ^failed, :failure, _duration}, :ok}
    refute_receive {:recorder, {:complete, _, _, _}, _}
  end

  @spec fake_recorder(pid()) :: no_return()
  defp fake_recorder(test) do
    receive do
      {:"$gen_call", from, {:admit, _owner, _deadline} = request} ->
        ticket = make_ref()
        send(test, {:recorder, request, ticket})
        GenServer.reply(from, ticket)

      {:"$gen_call", from, {:complete, _ticket, _outcome, _duration} = request} ->
        send(test, {:recorder, request, :ok})
        GenServer.reply(from, :ok)
    end

    fake_recorder(test)
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @spec assert_measured(LiveObservability.phase()) :: :ok
  defp assert_measured(phase) do
    assert_receive {:callback, measurements, %{phase: ^phase} = metadata}

    assert metadata == %{live_view: :overview_live, phase: phase}
    assert Map.keys(measurements) |> Enum.sort() == [:duration, :queries]
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert is_integer(measurements.queries) and measurements.queries >= 0
    :ok
  end
end
