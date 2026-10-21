defmodule Marshall.Accounts.AdminEventsTest do
  use Marshall.DataCase, async: false

  alias Marshall.Accounts.{AdminEvent, User}

  test "audit cursors follow timestamp and UUID ties without skipping or repeating receipts" do
    actor = administrator()
    older = ~U[2026-01-01 00:00:00.000000Z]
    newer = ~U[2026-01-02 00:00:00.000000Z]
    first = receipt(actor, "00000000-0000-4000-8000-000000000002", newer)
    second = receipt(actor, "00000000-0000-4000-8000-000000000001", newer)
    third = receipt(actor, "ffffffff-ffff-4fff-8fff-ffffffffffff", older)

    assert {:ok, %{items: [%{id: first_id}], next_cursor: first_id}} = page(actor, nil)
    assert first_id == first.id
    assert {:ok, %{items: [%{id: second_id}], next_cursor: second_id}} = page(actor, first_id)
    assert second_id == second.id
    assert {:ok, %{items: [%{id: third_id}], next_cursor: nil}} = page(actor, second_id)
    assert third_id == third.id
    assert {:ok, %{items: [], next_cursor: nil}} = page(actor, third_id)
  end

  test "an unknown cursor cannot restart audit history" do
    actor = administrator()
    receipt(actor, Ash.UUID.generate(), ~U[2026-01-01 00:00:00.000000Z])
    assert {:ok, %{items: [], next_cursor: nil}} = page(actor, Ash.UUID.generate())
  end

  @spec administrator() :: User.t()
  defp administrator do
    Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: true})
    |> Marshall.PasskeyFixture.verified_session()
  end

  @spec receipt(User.t(), String.t(), DateTime.t()) :: AdminEvent.t()
  defp receipt(actor, id, timestamp) do
    Ash.Seed.seed!(AdminEvent, %{
      id: id,
      actor_id: actor.id,
      target_id: actor.id,
      kind: :grant,
      inserted_at: timestamp
    })
  end

  @spec page(User.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defp page(actor, before) do
    AdminEvent
    |> Ash.ActionInput.for_action(:list_for_admin, %{before: before, limit: 1}, actor: actor)
    |> Ash.run_action()
  end
end
