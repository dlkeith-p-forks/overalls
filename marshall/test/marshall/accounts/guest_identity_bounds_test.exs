defmodule Marshall.Accounts.GuestIdentityBoundsTest do
  use Marshall.DataCase, async: false

  alias Marshall.Accounts.{GuestAccount, GuestAccounts, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:verification;recovery] allocation-exhaustion-boundary-oracle
  # The real finite sequence MUST refuse atomically, including a batch whose
  # earlier allocation succeeded. Sequence restart is test-transaction-local
  # and MUST never reset the shared committed sequence with setval/2 or /3.
  test "UID exhaustion rolls back earlier successful batch allocations" do
    left = account("batch.left")
    right = account("batch.right")
    restart_sequence!(999_999)
    before = projection()

    assert {:error, :guest_identity_unavailable} =
             Ledger.transaction(fn -> GuestAccounts.ensure_all!([right.id, left.id]) end)

    assert projection() == before
    assert [] == Ledger.read!(GuestAccount, user_id: left.id)
    assert [] == Ledger.read!(GuestAccount, user_id: right.id)
  end

  test "existing identities survive email changes and resolve after UID exhaustion" do
    user = account("last.uid")
    assert {:ok, previous} = Ledger.transaction(fn -> GuestAccounts.ensure!(user.id) end)
    changed = Ledger.update!(user, :security_state, %{email: "root+tag@example.test"})
    restart_sequence!(999_999)
    assert [[999_999]] == sql!("SELECT nextval('account_guest_uid_seq')").rows
    assert {:ok, same} = Ledger.transaction(fn -> GuestAccounts.ensure!(changed.id) end)

    assert {same.id, same.user_id, same.username, same.uid, same.retired_at, same.inserted_at,
            same.updated_at} ==
             {previous.id, previous.user_id, previous.username, previous.uid, previous.retired_at,
              previous.inserted_at, previous.updated_at}

    fresh = account("unavailable")
    before = projection()

    assert {:error, :guest_identity_unavailable} =
             Ledger.transaction(fn -> GuestAccounts.ensure!(fresh.id) end)

    assert projection() == before

    assert [[200_000, 999_999, false]] ==
             sql!(
               "SELECT min_value, max_value, cycle FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'account_guest_uid_seq'"
             ).rows
  end

  test "batch deduplicates and sorts users and refuses oversized or missing-user batches" do
    left = account("sorted.left")
    right = account("sorted.right")

    assert {:ok, allocated} =
             Ledger.transaction(fn ->
               GuestAccounts.ensure_all!([right.id, left.id, right.id])
             end)

    assert Enum.map(allocated, & &1.user_id) == Enum.sort([left.id, right.id])
    before = projection()

    for ids <- [Enum.map(1..513, fn _ -> Ash.UUID.generate() end), [left.id, Ash.UUID.generate()]] do
      assert {:error, _} = Ledger.transaction(fn -> GuestAccounts.ensure_all!(ids) end)
      assert projection() == before
    end
  end

  @spec account(String.t()) :: User.t()
  defp account(local),
    do: Ash.Seed.seed!(User, %{email: local <> "@example.test"}, actor: SystemActor.compute())

  @spec projection() :: [{String.t(), String.t(), String.t(), integer(), DateTime.t() | nil}]
  defp projection,
    do:
      GuestAccount
      |> Ledger.read!()
      |> Enum.map(&{&1.id, &1.user_id, &1.username, &1.uid, &1.retired_at})
      |> Enum.sort()

  @spec restart_sequence!(200_000..999_999) :: :ok
  defp restart_sequence!(first) when first in 200_000..999_999 do
    sql!("ALTER SEQUENCE account_guest_uid_seq RESTART WITH " <> Integer.to_string(first))
    :ok
  end

  @spec sql!(String.t()) :: Postgrex.Result.t()
  defp sql!(query), do: Ecto.Adapters.SQL.query!(Marshall.Repo, query, [], log: false)
end
