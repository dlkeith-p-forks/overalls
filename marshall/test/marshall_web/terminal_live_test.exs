defmodule MarshallWeb.TerminalLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "the Boot log entry reads host diagnostics without automatically opening a guest terminal",
       %{
         conn: conn
       } do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    actor = Ash.Resource.put_metadata(fixture.owner, :token, fixture.token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    assert {:ok, view, _} = live(conn, "/machines/#{fixture.vm.id}/terminals?view=boot-log")
    assert has_element?(view, "#machine-boot-log[aria-current='page']")
    assert has_element?(view, "#terminal-client[data-view='boot-log']")
    refute has_element?(view, "#terminal-create")
    assert Marshall.Compute.Ledger.read!(Marshall.Terminal.Session, vm_id: fixture.vm.id) == []

    render_hook(view, "terminal_boot_log", %{"cursor" => "0"})
    assert_reply(view, %{ok: true, next: 0, text: ""})
    send(view.pid, :refresh_terminals)
    assert has_element?(view, "#machine-boot-log[aria-current='page']")
    assert Marshall.Compute.Ledger.read!(Marshall.Terminal.Session, vm_id: fixture.vm.id) == []
  end

  test "connected workspace initializes and renders a newly created registry session", %{
    conn: conn
  } do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    assert is_pid(stream)
    actor = Ash.Resource.put_metadata(fixture.owner, :token, fixture.token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    assert {:ok, view, _} = live(conn, "/machines/#{fixture.vm.id}/terminals")
    assert has_element?(view, "#terminal-client")
    assert has_element?(view, "#terminal-boot-xterm[aria-label='Read-only boot console']")

    assert has_element?(
             view,
             "#terminal-fullscreen[aria-label='Enter full screen'][aria-pressed='false']"
           )

    refute has_element?(view, "#terminal-boot-view pre")

    assert_push_event(
      view,
      "terminal_sessions",
      %{sessions: [%{id: id, guest_user: username}]},
      2000
    )

    [account] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.GuestAccount, user_id: fixture.owner.id)

    assert username == account.username
    assert username == "u#{account.uid}"

    assert OverallsProtocol.uuid?(id)
    assert has_element?(view, "#terminal-item-#{id}[role=option]")
    assert has_element?(view, "[data-terminal-share='#{id}']")
    assert has_element?(view, "[data-terminal-kill='#{id}']")
    {:ok, reloaded, _} = live(conn, "/machines/#{fixture.vm.id}")
    assert has_element?(reloaded, "#terminal-item-#{id}")
    request_id = Ash.UUID.generate()
    render_hook(reloaded, "terminal_new", %{"user" => "root", "request_id" => request_id})
    render_hook(reloaded, "terminal_new", %{"user" => "other-user", "request_id" => request_id})
    assert {:ok, sessions} = Marshall.Terminal.Authority.list_sessions(fixture.vm, fixture.owner)
    assert length(sessions) == 2
    assert Enum.all?(sessions, &(&1.user == username))

    render_hook(reloaded, "terminal_new", %{"request_id" => "invalid"})
    assert has_element?(reloaded, "#terminal-notice", "The terminal could not be opened.")

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         :ok = Marshall.Terminal.Relay.register(fixture.host.id, self())
         send(parent, :listing_faults_ready)

         for reason <- [:stream_timeout, :rejected] do
           receive do
             {:relay_control, request} -> Marshall.Terminal.Relay.reply(request, {:error, reason})
           end
         end
       end},
      id: :listing_faults
    )

    assert_receive :listing_faults_ready

    for _ <- 1..2 do
      send(reloaded.pid, :refresh_terminals)
      assert has_element?(reloaded, "#terminal-notice", "The terminal could not be opened.")
    end

    :ok = Marshall.Terminal.Relay.register(fixture.host.id, stream)
    render_hook(reloaded, "terminal_new", %{"request_id" => Ash.UUID.generate()})
    refute has_element?(reloaded, "#terminal-notice")
  end

  test "an unavailable stream yields a notice without crashing the connected workspace", %{
    conn: conn
  } do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    actor = Ash.Resource.put_metadata(fixture.owner, :token, fixture.token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    assert {:ok, view, _} = live(conn, "/machines/#{fixture.vm.id}/terminals")
    assert has_element?(view, "#terminal-notice", "Preparing your terminal")

    for _ <- 1..3 do
      send(view.pid, :refresh_terminals)
      assert has_element?(view, "#terminal-notice", "Preparing your terminal")
    end

    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    send(view.pid, :refresh_terminals)
    assert_push_event(view, "terminal_sessions", %{sessions: [%{id: id}]}, 2000)
    assert has_element?(view, "#terminal-item-#{id}")
    send(view.pid, :refresh_terminals)
    assert has_element?(view, "#terminal-item-#{id}")
    assert {:ok, [_]} = Marshall.Terminal.Authority.list_sessions(fixture.vm, fixture.owner)
  end

  test "late replies do not crash or change a connected workspace", %{conn: conn} do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    actor = Ash.Resource.put_metadata(fixture.owner, :token, fixture.token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    assert {:ok, view, _} = live(conn, "/machines/#{fixture.vm.id}")
    assert_push_event(view, "terminal_sessions", %{sessions: [%{id: id}]}, 2000)

    for result <- [{:error, :timeout}, {:ok, %{type: :listed, sessions: []}}] do
      send(view.pid, {:relay_reply, make_ref(), result})
      assert has_element?(view, "#terminal-item-#{id}")
    end
  end

  test "provisioning waits without polling the guest and failed boots remain visible", %{
    conn: conn
  } do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    alias Marshall.Compute.{Ledger, VirtualMachine}
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)
    vm = Ledger.update!(vm, :observe, %{observed_state: :pending})
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         :ok = Marshall.Terminal.Relay.register(fixture.host.id, self())
         send(parent, :waiting_stream_ready)

         receive do
           {:relay_control, request} ->
             send(parent, :unexpected_guest_query)
             Marshall.Terminal.Relay.reply(request, {:error, :stream_unavailable})
         end
       end}
    )

    assert_receive :waiting_stream_ready
    actor = Ash.Resource.put_metadata(fixture.owner, :token, fixture.token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    assert {:ok, view, _} = live(conn, "/machines/#{fixture.vm.id}")
    assert has_element?(view, "#terminal-notice", "Waiting for the machine to start")
    refute_receive :unexpected_guest_query, 0

    Ledger.update!(vm, :observe, %{observed_state: :failed})
    send(view.pid, :refresh_terminals)
    assert has_element?(view, "#terminal-notice", "Machine startup failed")
    refute_receive :unexpected_guest_query, 0
  end
end
