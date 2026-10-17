defmodule Marshall.SSH.CredentialRetirementHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.CredentialRetirementFixture, as: Fixture
  alias Marshall.SSH

  @type generation :: {Fixture.operation(), boolean(), pos_integer()}

  # @cc [owner:ghuntley,label:verification] credential-generated-retirement-history
  # Each fresh same-email identity MUST explicitly register the released key;
  # old registration IDs and sessions MUST NOT return. Refused stale calls and
  # repeated completed cleanup MUST preserve exact durable inventories.
  @tag timeout: 120_000
  property "same-email histories release credentials only through old-account cleanup" do
    check all(
            bytes <- binary(length: 32),
            generations <-
              list_of(tuple({member_of([:manual, :approval]), boolean(), integer(1..3)}),
                min_length: 2,
                max_length: 3
              ),
            max_runs: 12
          ) do
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      account = Marshall.PasskeyFixture.user()

      Enum.reduce(generations, account, fn generation, current ->
        advance(generation, current, admin, bytes)
      end)
    end
  end

  @spec advance(generation(), User.t(), User.t(), binary()) :: User.t()
  defp advance({operation, replace, retries}, current, admin, bytes) do
    {actor, _token} = Marshall.PasskeyFixture.login(current)
    fixture = Fixture.registration(bytes)
    assert {:ok, _} = Fixture.register(operation, fixture, actor)
    assert [first_key] = Ledger.read!(SSH.Key, user_id: current.id)

    for _ <- 1..retries do
      assert {:ok, same} = Fixture.register(:manual, fixture, actor)
      assert same.id == first_key.id
    end

    key =
      if replace do
        assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: first_key.id}, actor: actor)
        assert {:ok, replacement} = Fixture.register(:manual, fixture, actor)
        refute replacement.id == first_key.id
        replacement
      else
        first_key
      end

    assert {:ok, %{id: deletion_id}} = Fixture.retire(admin, actor)
    fresh = fresh(to_string(current.email))
    refute fresh.id == current.id
    assert Ledger.read!(SSH.Key, user_id: fresh.id) == []
    before_cleanup = Fixture.snapshot(current.id, fixture)
    assert before_cleanup.retired
    assert before_cleanup.deletions == [{deletion_id, false, 0, false}]
    assert {:error, _} = Fixture.register(:manual, fixture, fresh)
    assert Fixture.snapshot(current.id, fixture) == before_cleanup
    assert {:ok, %{complete: true}} = Fixture.complete(deletion_id)

    completed = Fixture.snapshot(current.id, fixture)
    assert completed.deletions == [{deletion_id, true, 0, false}]
    assert Enum.all?(completed.keys, &elem(&1, 2))
    assert Ledger.read!(SSH.Key, user_id: current.id) == []

    for _ <- 1..retries do
      for stale <- [:manual, :approval] do
        assert {:error, _} = Fixture.register(stale, fixture, actor)
        assert Fixture.snapshot(current.id, fixture) == completed
      end

      assert {:ok, %{id: ^deletion_id}} = Fixture.retire(admin, actor)
      assert {:ok, %{complete: true}} = Fixture.complete(deletion_id)
      assert Fixture.snapshot(current.id, fixture) == completed
    end

    assert {:ok, replacement} = Fixture.register(:manual, fixture, fresh)
    refute replacement.id in Enum.map(completed.keys, &elem(&1, 0))

    assert [%{actor_kind: :user, actor_id: fresh_id}] =
             Ledger.read!(SSH.Key.Version, version_source_id: replacement.id)

    assert fresh_id == fresh.id
    assert {:ok, %{complete: true}} = Fixture.complete(deletion_id)
    assert [%{id: replacement_id}] = Ledger.read!(SSH.Key, user_id: fresh.id)
    assert replacement_id == replacement.id
    assert Fixture.snapshot(current.id, fixture) == completed

    result =
      SSH.session_status(
        %{gateway_token: fixture.gateway_token, session_token: fixture.session_token},
        actor: SystemActor.compute()
      )

    if operation == :approval do
      assert {:error, _} = result
    else
      assert {:ok, %{status: "pending"}} = result
    end

    assert Enum.any?(completed.keys, &(elem(&1, 0) == key.id))
    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: replacement.id}, actor: fresh)
    fresh
  end

  @spec fresh(String.t()) :: User.t()
  defp fresh(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    User
    |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.create!()
  end
end
