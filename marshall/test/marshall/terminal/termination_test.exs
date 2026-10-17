defmodule Marshall.Terminal.TerminationTest do
  use Marshall.DataCase, async: false
  alias Marshall.Terminal.{Authority, Event, Reconciler, Session, Termination}

  test "lost kill acknowledgement retains intent, fences tickets and recovers one receipt" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    reference = make_ref()
    send(stream, {:lose_next_kill_reply, self(), reference})
    assert_receive {:kill_reply_loss_armed, ^reference}

    assert {:error, :terminal_close_pending} = Authority.close_session(session, fixture.owner)

    assert {:ok, %Session{kill_status: :pending}} =
             Ash.get(Session, session.id, authorize?: false)

    assert {:error, :unknown_session} = Authority.ticket(session, fixture.owner)
    assert Enum.count(receipts(session.id), &(&1.kind == :kill_requested)) == 1
    refute Enum.any?(receipts(session.id), &(&1.kind == :killed))

    assert :ok = Reconciler.reconcile_vm(session.vm_id)
    assert :ok = Reconciler.reconcile_vm(session.vm_id)
    assert {:ok, []} = Marshall.Terminal.list_for_vm(session.vm_id, authorize?: false)
    assert Enum.count(receipts(session.id), &(&1.kind == :kill_requested)) == 1
    assert Enum.count(receipts(session.id), &(&1.kind == :killed)) == 1
  end

  test "an older listing snapshot observes kill intent under the archive lock" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, snapshot} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert snapshot.kill_status == :idle
    assert {:ok, pending} = Termination.request(snapshot, fixture.owner)
    assert {:ok, retried} = Termination.request(snapshot, fixture.owner)
    assert pending.id == retried.id

    send(stream, {:guest_exited, snapshot.guest_session_id})

    assert {:ok, %{sessions: []}} =
             Marshall.Terminal.Relay.control(stream, %{
               type: :listing,
               vm_id: snapshot.vm_id,
               placement_id: snapshot.placement_id,
               execution_epoch: snapshot.execution_epoch
             })

    # The observer has already obtained authoritative absence but still holds
    # the pre-request registry snapshot. Confirmation must inspect the new state.
    assert :ok = Termination.observe_absent(snapshot, false, fixture.owner.id)
    assert :ok = Termination.confirm(pending)
    assert Enum.count(receipts(snapshot.id), &(&1.kind == :kill_requested)) == 1
    assert Enum.count(receipts(snapshot.id), &(&1.kind == :killed)) == 1
    refute Enum.any?(receipts(snapshot.id), &(&1.kind == :closed))
  end

  test "retired placement authority does not claim a physical guest kill" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, pending} = Termination.request(session, fixture.owner)
    assert :ok = Termination.retire(pending)

    assert [%{kind: :closed, actor_id: nil}] =
             Enum.filter(receipts(session.id), &(&1.kind == :closed))

    refute Enum.any?(receipts(session.id), &(&1.kind == :killed))
  end

  @spec receipts(String.t()) :: [Event.t()]
  defp receipts(id),
    do: Event |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.session_id == id))
end
