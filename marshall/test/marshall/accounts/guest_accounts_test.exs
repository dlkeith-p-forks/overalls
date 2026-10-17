defmodule Marshall.Accounts.GuestAccountsTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties

  alias Marshall.Accounts.{GuestAccount, GuestAccounts, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  test "equal local parts on different domains have distinct permanent identities" do
    left = account("same.name@example.test")
    right = account("same.name@elsewhere.test")
    first = ensure!(left)
    second = ensure!(right)
    assert first.username == "u#{first.uid}"
    assert second.username == "u#{second.uid}"
    refute first.uid == second.uid
    refute first.id == second.id
    assert identity(ensure!(right)) == identity(second)
  end

  # @cc [owner:ghuntley,label:verification;security] durable-email-history-oracle
  # Generated email changes MUST preserve the User and GuestAccount UUIDs,
  # numeric UID and Linux login without creating historical guest incarnations.
  property "email changes and changes back preserve one lifetime identity" do
    check all(changes <- integer(1..8), max_runs: 12) do
      prefix = binary_part(Ash.UUID.generate(), 0, 16)
      email = "original-#{prefix}@example.test"
      user = account(email)
      first = ensure!(user)

      changed =
        Enum.reduce(1..changes, user, fn iteration, current ->
          updated =
            Ledger.update!(current, :security_state, %{
              email: "9person+#{prefix}-#{iteration}@elsewhere.test"
            })

          assert updated.id == user.id
          assert identity(ensure!(updated)) == identity(first)
          updated
        end)

      restored = Ledger.update!(changed, :security_state, %{email: email})
      assert identity(ensure!(restored)) == identity(first)

      assert Enum.map(Ledger.read!(GuestAccount, user_id: user.id), &identity/1) == [
               identity(first)
             ]
    end
  end

  test "actual retirement reserves identity and same-email replacement inherits nothing" do
    user = account("retained.home@example.test")
    first = ensure!(user)
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

    assert {:ok, %{deleting: true}} =
             User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               actor: admin
             )
             |> Ash.run_action()

    assert {:error, :unauthorized} = Ledger.transaction(fn -> GuestAccounts.ensure!(user.id) end)
    assert [preserved] = Ledger.read!(GuestAccount, id: first.id)
    assert %DateTime{} = preserved.retired_at

    assert {:error,
            %Postgrex.Error{postgres: %{code: :unique_violation, constraint: "users_pkey"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO users (id, email) VALUES ($1, $2)",
               [Ecto.UUID.dump!(user.id), "unused@example.test"],
               mode: :savepoint,
               log: false
             )

    assert {preserved.id, preserved.user_id, preserved.username, preserved.uid} ==
             {first.id, first.user_id, first.username, first.uid}

    fresh = account("retained.home@example.test")
    next = ensure!(fresh)
    refute fresh.id == user.id
    refute next.id == first.id
    refute next.uid == first.uid
    refute next.username == first.username
    assert next.username == "u#{next.uid}"
    assert [] == Ledger.read!(Marshall.SSH.Key, user_id: fresh.id)
    assert [] == Ledger.read!(Marshall.Access.Grant, user_id: fresh.id)
    assert [] == Ledger.read!(Marshall.Teams.TeamMember, user_id: fresh.id)
  end

  test "PostgreSQL rejects canonical-name violations and duplicate current users" do
    user = account("constraints@example.test")
    current = ensure!(user)

    [[next_uid]] =
      Ecto.Adapters.SQL.query!(Repo, "SELECT nextval('account_guest_uid_seq')", [], log: false).rows

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :check_violation,
                constraint: "account_guest_accounts_username_uid"
              }
            }} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO account_guest_accounts (user_id, username, uid) VALUES ($1, $2, $3)",
               [Ecto.UUID.dump!(user.id), "person", next_uid],
               mode: :savepoint,
               log: false
             )

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :unique_violation,
                constraint: "account_guest_accounts_current_user_index"
              }
            }} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO account_guest_accounts (user_id, username, uid) VALUES ($1, $2, $3)",
               [Ecto.UUID.dump!(user.id), "u#{next_uid}", next_uid],
               mode: :savepoint,
               log: false
             )

    assert Enum.map(Ledger.read!(GuestAccount, user_id: user.id), &identity/1) == [
             identity(current)
           ]
  end

  test "retired UUIDs and UIDs remain reserved by PostgreSQL" do
    user = account("permanent@example.test")
    previous = ensure!(user)
    Ledger.update!(previous, :retire, %{retired_at: Ledger.now()})
    fresh = account("different@example.test")

    [[next_uid]] =
      Ecto.Adapters.SQL.query!(Repo, "SELECT nextval('account_guest_uid_seq')", [], log: false).rows

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :unique_violation, constraint: "account_guest_accounts_pkey"}
            }} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO account_guest_accounts (id, user_id, username, uid) VALUES ($1, $2, $3, $4)",
               [
                 Ecto.UUID.dump!(previous.id),
                 Ecto.UUID.dump!(fresh.id),
                 "u#{next_uid}",
                 next_uid
               ],
               mode: :savepoint,
               log: false
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO account_guest_accounts (user_id, username, uid) VALUES ($1, $2, $3)",
               [Ecto.UUID.dump!(fresh.id), previous.username, previous.uid],
               mode: :savepoint,
               log: false
             )

    assert [] == Ledger.read!(GuestAccount, user_id: fresh.id)
  end

  @spec identity(GuestAccount.t()) ::
          {String.t(), String.t(), String.t(), pos_integer(), DateTime.t() | nil, DateTime.t(),
           DateTime.t()}
  defp identity(account),
    do:
      {account.id, account.user_id, account.username, account.uid, account.retired_at,
       account.inserted_at, account.updated_at}

  @spec ensure!(User.t()) :: GuestAccount.t()
  defp ensure!(user) do
    assert {:ok, account} = Ledger.transaction(fn -> GuestAccounts.ensure!(user.id) end)
    account
  end

  @spec account(String.t()) :: User.t()
  defp account(email),
    do: Ash.Seed.seed!(User, %{email: email}, actor: SystemActor.compute())
end
