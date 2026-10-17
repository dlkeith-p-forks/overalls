defmodule Marshall.Terminal.TicketsTest do
  use Marshall.DataCase, async: true

  alias Marshall.Terminal.Tickets
  alias Marshall.Authorization.SystemActor
  alias Marshall.Terminal.{Ticket, TicketRetention}

  test "ticket is actor-bound, short-lived and consumed exactly once" do
    session_id = Ash.UUID.generate()
    actor_id = Ash.UUID.generate()

    assert {:ok, token} = Tickets.issue(session_id, actor_id, :rw)
    refute token =~ session_id
    refute token =~ actor_id

    assert {:ok, %{session_id: ^session_id, actor_id: ^actor_id, mode: :rw}} =
             Tickets.consume(token)

    assert {:error, :invalid_ticket} = Tickets.consume(token)
  end

  test "invalid tickets fail closed" do
    assert {:error, :invalid_ticket} = Tickets.consume("too-short")
    assert {:error, :invalid_ticket} = Tickets.consume(String.duplicate("x", 43))
  end

  test "retention deletes only tickets expired for an hour in a bounded job action" do
    old_id = Ash.UUID.generate()
    recent_id = Ash.UUID.generate()
    active_id = Ash.UUID.generate()
    now = DateTime.utc_now()

    create_ticket(old_id, DateTime.add(now, -3601))
    create_ticket(recent_id, DateTime.add(now, -60))
    create_ticket(active_id, DateTime.add(now, 30))

    assert {:ok, 1} = TicketRetention.run(nil, nil, %{actor: SystemActor.compute()})

    ids = Ticket |> Ash.read!(authorize?: false) |> MapSet.new(& &1.session_id)
    refute MapSet.member?(ids, old_id)
    assert MapSet.member?(ids, recent_id)
    assert MapSet.member?(ids, active_id)
  end

  defp create_ticket(session_id, expires_at) do
    assert {:ok, _ticket} =
             Marshall.Terminal.create_ticket(
               %{
                 token_hash: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower),
                 session_id: session_id,
                 actor_id: Ash.UUID.generate(),
                 mode: :ro,
                 expires_at: expires_at
               },
               authorize?: false
             )
  end
end
