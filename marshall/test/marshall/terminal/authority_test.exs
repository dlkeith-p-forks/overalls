defmodule Marshall.Terminal.AuthorityTest do
  use Marshall.DataCase, async: false

  alias Marshall.Terminal.Authority
  alias Marshall.Compute.{HostLiveness, Ledger}
  import Hegel
  import Hegel.Gen

  # @cc [owner:ghuntley,label:verification;security] terminal-wake-admission-history
  # Generated authorized/foreign request histories MUST coalesce only authorized
  # wake demand without creating sessions or guest tickets while physically paused.
  # Seeded BEAM observations do not establish snapshot or KVM correctness.
  property "paused terminal retries coalesce only after current authorization",
    test_cases: 16,
    seed: 2_026_101_803 do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stranger = Marshall.ComputeFixtures.user()
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})

    history =
      draw("authorized request history", list_of(boolean(), min_length: 1, max_length: 12))

    for authorized <- history do
      actor = if authorized, do: fixture.owner, else: stranger
      expected = if authorized, do: :terminal_open_pending, else: :forbidden
      assert {:error, ^expected} = Authority.ensure_awake(fixture.vm, actor)
    end

    wakes = Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id)
    assert length(wakes) == if(Enum.any?(history), do: 1, else: 0)
    assert Ledger.read!(Marshall.Terminal.Session, vm_id: vm.id) == []
  end

  # @cc [owner:ghuntley,label:verification;recovery] terminal-passive-polls-do-not-wake
  # An attached viewer's periodic authority check MUST refuse a paused guest
  # without creating wake demand, a new registry row or an attach ticket.
  test "passive viewer checks do not wake a paused machine" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    state = attach_viewer(fixture, fixture.owner, fixture.token)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})

    assert {:error, :terminal_unavailable} =
             Authority.session_for(state.session.id, fixture.owner)

    assert {:error, :terminal_unavailable} = Authority.host_for(state.session)
    assert_authority_refusal(state, :authority_host)
    assert Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id) == []
    assert [%{id: session_id}] = Ledger.read!(Marshall.Terminal.Session, vm_id: vm.id)
    assert session_id == state.session.id
    assert Ledger.read!(Marshall.Terminal.Ticket, session_id: state.session.id) == []
    Marshall.Terminal.Viewer.terminate(:normal, state)
  end

  test "an automatic opening cannot wake after a pause wins its listing race" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})

    assert {:error, :terminal_unavailable} =
             Authority.open_personal_session(fixture.vm, fixture.owner, :default, :observe)

    assert Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id) == []
    assert Ledger.read!(Marshall.Terminal.Session, vm_id: vm.id) == []
    assert Ledger.read!(Marshall.Terminal.Opening, vm_id: vm.id) == []
  end

  # @cc [owner:ghuntley,label:verification;security] terminal-viewer-demand-is-authorized
  # A new shared read-only connection MAY wake a paused guest only after current
  # machine and session authority. Pending readiness MUST grant no ticket or
  # guest control, and retries MUST join the same wake request.
  test "a shared read-only connection joins wake only after current authorization" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    member = Marshall.ComputeFixtures.user()
    stranger = Marshall.ComputeFixtures.user()
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :viewer)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert :ok =
             Marshall.Terminal.Sharing.set(
               session,
               fixture.owner,
               to_string(member.email),
               :shared
             )

    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})
    Process.exit(stream, :shutdown)

    assert {:error, :forbidden} = Authority.ticket(session, stranger)
    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :revoked)
    assert {:error, :forbidden} = Authority.ticket(session, member)
    assert Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id) == []

    assert {:ok, _grant} = Marshall.TerminalFixtures.grant(fixture, member, :viewer)

    for _ <- 1..3 do
      assert {:error, :terminal_open_pending} = Authority.ticket(session, member)
    end

    assert [%{source: :network, requested_by_id: requester}] =
             Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id)

    assert requester == member.id
    assert Ledger.read!(Marshall.Terminal.Ticket, session_id: session.id) == []
    assert [%{id: session_id}] = Ledger.read!(Marshall.Terminal.Session, vm_id: vm.id)
    assert session_id == session.id
  end

  test "paused boot-log reads remain diagnostic and create no wake demand" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})

    assert {:ok, %{next: 0, bytes: ""}} = Authority.boot_log(fixture.vm, fixture.owner, 0)
    assert Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id) == []
    assert Ledger.read!(Marshall.Terminal.Session, vm_id: vm.id) == []
    assert Ledger.read!(Marshall.Terminal.Ticket) == []
  end

  # @cc [owner:ghuntley,label:verification;security] native-diagnostics-retained-placement-fixture
  # The synthetic retained placement MUST exercise the durable native image's
  # disabled capabilities even when the caller holds a previous VM snapshot.
  # Seeding its image identity MUST NOT establish native admission or execution.
  test "pending and failed native images permit boot-log reads while terminals stay disabled" do
    image = Marshall.ComputeFixtures.native_image_fixture()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    vm = Ash.Seed.update!(vm, %{image_id: image.id})

    refute Marshall.Compute.Images.guest_capabilities(image.id).terminal

    for state <- [:pending, :failed] do
      Ledger.update!(vm, :observe, %{observed_state: state})
      assert {:ok, %{next: 0, bytes: ""}} = Authority.boot_log(fixture.vm, fixture.owner, 0)
      assert {:error, :terminal_unavailable} = Authority.list_sessions(fixture.vm, fixture.owner)

      assert {:error, :terminal_unavailable} =
               Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")
    end
  end

  test "boot-log reads still refuse foreign actors and stale or unsupported host streams" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    stranger = Marshall.ComputeFixtures.user()
    assert {:error, :forbidden} = Authority.boot_log(fixture.vm, stranger, 0)

    [host] = Ledger.read!(Marshall.Compute.Host, id: fixture.host.id)
    inventory = host.inventory

    for attributes <- [
          %{inventory: Map.put(inventory, "terminal_protocol", 1)},
          %{
            inventory: inventory,
            reported_at:
              DateTime.add(Ledger.now(), -(HostLiveness.authority_ms() + 1), :millisecond)
          }
        ] do
      Ledger.update!(host, :report, attributes)
      assert {:error, :terminal_unavailable} = Authority.boot_log(fixture.vm, fixture.owner, 0)
    end
  end

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

  # @cc [owner:ghuntley,label:verification;security] restored-guest-does-not-adopt-old-terminal-authority
  # A guest session number surviving in memory MUST NOT rebind an old registry
  # session to a newer execution epoch. Authoritative listing MUST retire that
  # row once, even when the guest reports the same number as live. This seeded
  # BEAM authority test does not establish physical relocation or PTY continuity.
  test "a restored guest session number does not adopt an old execution's registry entry" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
    Ash.Seed.update!(vm, %{execution_epoch: vm.execution_epoch + 1})

    assert {:error, :unknown_session} = Authority.ticket(session, fixture.owner)
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:ok, []} = Marshall.Terminal.list_for_vm(fixture.vm.id, authorize?: false)
    assert Ledger.read!(Marshall.Compute.WakeRequest, vm_id: vm.id) == []
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
