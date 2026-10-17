defmodule Marshall.Terminal.SharingRevocationTest do
  use Marshall.DataCase, async: false

  @moduletag capture_log: true

  alias Marshall.Compute.Ledger
  alias Marshall.SharingSurfacesFixture, as: Fixture
  alias Marshall.Terminal.{Event, Session, Sharing, Tickets}
  alias Marshall.TerminalAttachmentSocket, as: Socket

  # @cc [owner:ghuntley,label:verification;security] terminal-share-revoke-live-viewer
  # Sharing.set(:revoked) MUST commit the grant archive with its receipt and MUST
  # NOT synchronously dispatch a relay control: a live shared read-only viewer
  # closes only through the documented one-second authority recheck. The guest
  # session MUST stay alive and unwatched viewer tickets MUST stay refused; a
  # later re-share MUST admit only through a fresh single-use ticket with a new
  # relay channel. The old ticket MUST never work again anywhere.
  test "live shared read-only viewer closes on the authority timer after sharing revocation" do
    c = Fixture.fixture()
    assert {:ok, _} = Fixture.grant(c, :operator)
    assert :ok = Sharing.set(c.session, c.owner, to_string(c.member.email), :shared)
    {:ok, ticket} = Fixture.terminal_ticket(c)
    assert {:ok, %{mode: :ro, session_id: session_id}} = Tickets.consume(ticket)
    assert session_id == c.session.id

    # A consumed ticket cannot attach; issue a fresh one for the live viewer.
    {:ok, live_ticket} = Fixture.terminal_ticket(c)
    client = Socket.connect(c.port, live_ticket, 41)
    {1, attached} = Socket.frame(client)

    %{"op" => "attached", "channel" => channel, "mode" => "ro"} = JSON.decode!(attached)

    revoked_at = System.monotonic_time(:millisecond)
    assert :ok = Sharing.set(c.session, c.owner, to_string(c.member.email), :revoked)

    # No synchronous relay dispatch accompanies the committed revocation.
    assert [{:attach, _, _}] = Fixture.effects(c)
    assert {:error, :forbidden} = Fixture.terminal_ticket(c)
    assert {:error, :invalid_ticket} = Tickets.consume(live_ticket)

    # The idle viewer closes without any client trigger, within the documented
    # one-second authority recheck period plus scheduling margin.
    Socket.closed(client)
    closed_after = System.monotonic_time(:millisecond) - revoked_at
    assert closed_after < 6500, "viewer closed #{closed_after}ms after revocation"

    assert [{:attach, _, _}, {:gone, ^channel}] = Fixture.effects(c)
    [session] = Ledger.read!(Session, id: c.session.id)
    assert session.kill_status == :idle

    events =
      Ledger.read!(Event, session_id: c.session.id)
      |> Enum.map(& &1.kind)

    assert Enum.count(events, &(&1 == :attached)) == 1
    assert Enum.count(events, &(&1 == :detached)) == 1
    assert Enum.count(events, &(&1 == :shared)) == 1
    assert Enum.count(events, &(&1 == :revoked)) == 1

    # Re-sharing restores admission only through fresh artifacts: a new ticket
    # and a new relay channel; nothing revives the revoked attachment.
    assert :ok = Sharing.set(c.session, c.owner, to_string(c.member.email), :shared)
    {:ok, restored} = Fixture.terminal_ticket(c)
    refute restored == live_ticket
    restored_client = Socket.connect(c.port, restored, 42)
    {1, restored_attached} = Socket.frame(restored_client)
    restored_attach = JSON.decode!(restored_attached)
    assert restored_attach["mode"] == "ro"
    assert restored_attach["channel"] > channel
    Socket.disconnect(restored_client)
    assert {:error, :invalid_ticket} = Tickets.consume(restored)
    assert {:error, :invalid_ticket} = Tickets.consume(live_ticket)

    assert [{:attach, _, _}, {:gone, _}, {:attach, _, _}, {:gone, _}] = Fixture.effects(c)
    [session] = Ledger.read!(Session, id: c.session.id)
    assert session.kill_status == :idle
  end

  # @cc [owner:ghuntley,label:verification;security] terminal-vm-revoke-live-shared-viewer
  # A direct VM grant revocation MUST close a live shared read-only viewer on
  # the same one-second recheck even though its terminal viewing grant remains;
  # current read permission decides every recheck.
  test "direct VM revocation closes a live shared viewer while its terminal grant remains" do
    c = Fixture.fixture()
    assert {:ok, _} = Fixture.grant(c, :operator)
    assert :ok = Sharing.set(c.session, c.owner, to_string(c.member.email), :shared)
    {:ok, ticket} = Fixture.terminal_ticket(c)
    client = Socket.connect(c.port, ticket, 7)
    {1, attached} = Socket.frame(client)
    %{"channel" => channel} = JSON.decode!(attached)

    assert {:ok, _} = Fixture.grant(c, :revoked)
    assert [{:attach, _, _}] = Fixture.effects(c)
    Socket.closed(client)
    assert [{:attach, _, _}, {:gone, ^channel}] = Fixture.effects(c)

    assert [_] = Ledger.read!(Marshall.Terminal.Grant, session_id: c.session.id)
    assert {:error, :forbidden} = Fixture.terminal_ticket(c)

    # Re-sharing the VM alone re-admits the surviving terminal grant.
    assert {:ok, _} = Fixture.grant(c, :operator)
    {:ok, restored} = Fixture.terminal_ticket(c)
    restored_client = Socket.connect(c.port, restored, 8)
    {1, restored_attached} = Socket.frame(restored_client)
    assert JSON.decode!(restored_attached)["channel"] > channel
    Socket.disconnect(restored_client)
  end
end
