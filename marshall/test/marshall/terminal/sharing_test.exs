defmodule Marshall.Terminal.SharingTest do
  use Marshall.DataCase, async: false
  alias Marshall.Terminal.{Authority, Sharing, Tickets, Event}

  test "machine operators see only explicitly shared terminals and always attach read-only" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, member, :operator)

    assert {:ok, first} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, second} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:ok, []} = Authority.list_sessions(fixture.vm, member)
    assert {:error, :forbidden} = Authority.ticket(first, member)
    assert :ok = Sharing.set(first, fixture.owner, to_string(member.email), :shared)
    assert :ok = Sharing.set(first, fixture.owner, to_string(member.email), :shared)
    assert {:ok, [visible]} = Authority.list_sessions(fixture.vm, member)
    assert visible.id == first.id
    assert {:error, :forbidden} = Authority.ticket(second, member)
    assert {:ok, ticket} = Authority.ticket(first, member)
    assert {:ok, %{mode: :ro}} = Tickets.consume(ticket)
    assert :ok = Sharing.set(first, fixture.owner, to_string(member.email), :revoked)
    assert {:error, :forbidden} = Authority.ticket(first, member)
    events = Ash.read!(Event, authorize?: false)
    assert Enum.count(events, &(&1.session_id == first.id and &1.kind == :shared)) == 1
    assert Enum.count(events, &(&1.session_id == first.id and &1.kind == :revoked)) == 1
  end

  test "terminal grants do not create VM access and non-owners cannot share" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    member = Marshall.ComputeFixtures.user()

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert {:error, :recipient_requires_vm_access} =
             Sharing.set(session, fixture.owner, to_string(member.email), :shared)

    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, member, :manager)

    assert {:error, :forbidden} =
             Sharing.set(session, member, to_string(fixture.owner.email), :shared)

    assert {:error, :recipient_requires_vm_access} =
             Sharing.set(session, fixture.owner, "missing@example.test", :shared)
  end
end
