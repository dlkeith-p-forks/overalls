defmodule Marshall.Terminal.AuthorityTest do
  use Marshall.DataCase, async: false

  alias Marshall.Terminal.Authority
  alias Marshall.Compute.{HostLiveness, Ledger}

  test "one owner can create fifty persistent terminals up to the VM limit" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)

    sessions =
      for _ <- 1..64 do
        assert {:ok, session} =
                 Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

        session
      end

    assert length(Enum.uniq_by(sessions, & &1.id)) == 64

    assert {:error, :too_many_terminal_sessions} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, listed} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert length(listed) == 64
  end

  test "authoritative guest listing retires exited sessions once and frees registry capacity" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    send(stream, {:guest_exited, session.guest_session_id})
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:ok, []} = Marshall.Terminal.list_for_vm(fixture.vm.id, authorize?: false)
    events = Ash.read!(Marshall.Terminal.Event, authorize?: false)
    assert Enum.count(events, &(&1.session_id == session.id and &1.kind == :closed)) == 1
  end

  test "registry resource retains authority identity without guest display metadata" do
    attributes =
      Marshall.Terminal.Session
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    assert :vm_id in attributes
    assert :owner_id in attributes
    assert :placement_id in attributes
    assert :execution_epoch in attributes
    assert :guest_session_id in attributes
    refute :guest_user in attributes
    refute :term in attributes
    refute :title in attributes
  end

  test "listings expose registry UUIDs and tickets consume across the shared store" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, [listed]} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert listed.id == session.id
    assert listed.guest_session_id == session.guest_session_id
    assert listed.user == "root"

    assert {:ok, ticket} = Authority.ticket(session, fixture.owner)

    assert {:ok, %{session_id: session_id, actor_id: actor_id, mode: :rw}} =
             Marshall.Terminal.Tickets.consume(ticket)

    assert session_id == session.id
    assert actor_id == fixture.owner.id
  end

  test "read-only viewers cannot kill sessions and owner kills close with one durable receipt" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)
    viewer = Marshall.ComputeFixtures.user()

    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, viewer, :viewer)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:error, :forbidden} = Authority.close_session(session, viewer)
    assert {:ok, still_open} = Ash.get(Marshall.Terminal.Session, session.id, authorize?: false)
    assert still_open.id == session.id

    assert :ok = Authority.close_session(session, fixture.owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(Marshall.Terminal.Session, session.id, authorize?: false)

    events = Ash.read!(Marshall.Terminal.Event, authorize?: false)
    assert Enum.count(events, &(&1.session_id == session.id and &1.kind == :denied)) == 1
    assert Enum.count(events, &(&1.session_id == session.id and &1.kind == :killed)) == 1
  end

  test "viewer attachment lifecycle records receipts without terminal bytes" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, ticket} = Authority.ticket(session, fixture.owner)

    assert {:push, {:text, _attached}, viewer_state} =
             Marshall.Terminal.Viewer.init(%{
               ticket: ticket,
               actor: fixture.owner,
               cursor: 0,
               login_jti: login_jti(fixture)
             })

    assert :ok = Marshall.Terminal.Viewer.terminate(:normal, viewer_state)

    events =
      Marshall.Terminal.Event
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.session_id == session.id and &1.kind in [:attached, :detached]))

    assert Enum.sort(Enum.map(events, & &1.kind)) == [:attached, :detached]

    assert Enum.all?(events, fn event ->
             Map.keys(Map.from_struct(event))
             |> Enum.all?(&(&1 not in [:bytes, :payload, :input, :output]))
           end)
  end

  @spec login_jti(map()) :: String.t()
  defp login_jti(fixture) do
    {:ok, jti, _expiry} = Marshall.Accounts.Login.verify(fixture.token, fixture.owner)
    jti
  end

  test "attached viewers close after login removal and refuse subsequent input" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, ticket} = Authority.ticket(session, fixture.owner)
    jti = login_jti(fixture)

    assert {:push, {:text, _attached}, state} =
             Marshall.Terminal.Viewer.init(%{
               ticket: ticket,
               actor: fixture.owner,
               cursor: 0,
               login_jti: jti
             })

    assert {:ok, ^state} = Marshall.Terminal.Viewer.handle_info(:check_authority, state)

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti = $1", [jti],
      log: false
    )

    assert_authority_refusal(state, :authority_login)

    assert {:stop, :normal, ^state} =
             Marshall.Terminal.Viewer.handle_in({"input", [opcode: :binary]}, state)

    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  test "an already attached shared viewer closes when its grant is revoked" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :viewer)
    token = Marshall.TerminalFixtures.user_token(member)
    {:ok, jti, _expiry} = Marshall.Accounts.Login.verify(token, member)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert :ok =
             Marshall.Terminal.Sharing.set(
               session,
               fixture.owner,
               to_string(member.email),
               :shared
             )

    assert {:ok, ticket} = Authority.ticket(session, member)

    assert {:push, {:text, _attached}, state} =
             Marshall.Terminal.Viewer.init(%{
               ticket: ticket,
               actor: member,
               cursor: 0,
               login_jti: jti
             })

    assert state.mode == :ro
    assert {:ok, ^state} = Marshall.Terminal.Viewer.handle_info(:check_authority, state)
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :revoked)

    assert_authority_refusal(state, :authority_session)

    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  # @cc [owner:ghuntley,label:verification;security] viewer-revoked-on-hint
  # A committed grant revocation MUST emit a user hint, and that hint alone MUST
  # make an attached viewer recheck and close, without waiting for its poll.
  test "a grant revocation hint closes an attached shared viewer at once" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    on_exit(fn -> Process.exit(stream, :shutdown) end)
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :viewer)
    token = Marshall.TerminalFixtures.user_token(member)
    {:ok, jti, _expiry} = Marshall.Accounts.Login.verify(token, member)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert :ok =
             Marshall.Terminal.Sharing.set(
               session,
               fixture.owner,
               to_string(member.email),
               :shared
             )

    assert {:ok, ticket} = Authority.ticket(session, member)

    assert {:push, {:text, _attached}, state} =
             Marshall.Terminal.Viewer.init(%{
               ticket: ticket,
               actor: member,
               cursor: 0,
               login_jti: jti
             })

    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _event, _measure, meta, _ ->
        send(test, {:hint, meta.kind, meta.id})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    member_id = member.id
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :revoked)
    assert_receive {:hint, :user, ^member_id}

    logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert {:stop, :normal, ^state} =
                 Marshall.Terminal.Viewer.handle_info({:control_hint, :user, member_id}, state)
      end)

    assert logs =~ "reason=authority_session"
    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  # @cc [owner:ghuntley,label:verification;security] viewer-survives-late-report
  # A merely late host report MUST NOT close an attached viewer; a report older
  # than the host authority window MUST (ADR-0140).
  test "an attached viewer survives a late report and closes once the host is lost" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    state = attach_viewer(fixture, fixture.owner, fixture.token)

    host =
      Ledger.update!(fixture.host, :report, %{
        reported_at: DateTime.add(Ledger.now(), -10, :second)
      })

    assert {:ok, _} = Marshall.Terminal.Viewer.handle_info(:check_authority, state)

    lost_at = DateTime.add(Ledger.now(), -(HostLiveness.authority_ms() + 10_000), :millisecond)
    Ledger.update!(host, :report, %{reported_at: lost_at})
    assert_authority_refusal(state, :authority_host)
    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  test "an attached writer closes when downgraded to a viewer" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :operator)
    state = attach_viewer(fixture, member, Marshall.TerminalFixtures.user_token(member))
    assert state.mode == :rw

    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :viewer)
    assert {:ok, _session} = Authority.session_for(state.session.id, member)
    assert_authority_refusal(state, :authority_writer)
    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  @spec attach_viewer(map(), Marshall.Accounts.User.t(), String.t()) :: map()
  defp attach_viewer(fixture, actor, token) do
    assert {:ok, session} = Authority.open_session(fixture.vm, actor, "root", "xterm-256color")
    assert {:ok, ticket} = Authority.ticket(session, actor)
    assert {:ok, jti, _expiry} = Marshall.Accounts.Login.verify(token, actor)

    assert {:push, {:text, _attached}, state} =
             Marshall.Terminal.Viewer.init(%{
               ticket: ticket,
               actor: actor,
               cursor: 0,
               login_jti: jti
             })

    assert {:ok, ^state} = Marshall.Terminal.Viewer.handle_info(:check_authority, state)
    state
  end

  @spec assert_authority_refusal(map(), Marshall.Terminal.Viewer.refusal_reason()) :: true
  defp assert_authority_refusal(state, reason) do
    logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert {:stop, :normal, ^state} =
                 Marshall.Terminal.Viewer.handle_info(:check_authority, state)
      end)

    assert logs =~ "event=terminal.viewer_refused"
    assert logs =~ "reason=#{reason}"
  end
end
