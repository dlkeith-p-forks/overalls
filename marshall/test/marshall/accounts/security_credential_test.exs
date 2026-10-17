defmodule Marshall.Accounts.SecurityCredentialTest do
  use Marshall.DataCase, async: false
  import Marshall.PasskeyFixture
  alias Marshall.Accounts.{Login, Passkey, PasskeyChallenge, Security}
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Authorization.Cedar
  alias Marshall.Compute.Ledger
  require Ash.Query

  defp snapshot do
    for table <- [
          "account_passkeys",
          "account_verifications",
          "tokens",
          "account_passkey_challenges",
          "account_admin_events"
        ] do
      %{rows: rows, columns: columns} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM " <> table <> " ORDER BY 1, 2", [],
          log: false
        )

      {table, columns, rows}
    end
  end

  defp passkeys(id), do: Map.new(Ledger.read!(Passkey, user_id: id), &{&1.id, &1.label})

  defp passkey_id(actor, authenticator) do
    [record] =
      Passkey
      |> Ash.Query.filter(user_id == ^actor.id and credential_id == ^authenticator.id)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

    record.id
  end

  defp seed_passkey(user) do
    Ash.Seed.seed!(Passkey, %{
      user_id: user.id,
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: %{1 => 2},
      label: "Seed"
    })
  end

  # Atom rollback reasons surface through the generic action wrapper.
  @spec refusal(term(), atom()) :: true
  defp refusal(result, reason) do
    assert {:error, %Ash.Error.Unknown{} = error} = result
    assert Enum.any?(error.errors, &(&1.error == "unknown error: #{inspect(reason)}"))
    true
  end

  test "rename with missing, nil, empty or overlong labels is a closed refusal, not a raise" do
    actor = elevate(user())
    key = passkey_id(actor, actor.__metadata__.test_authenticator)
    before = snapshot()

    for label <- [nil, "", "   ", String.duplicate("x", 81), %{}] do
      assert refusal(action(actor, :rename, %{"id" => key, "label" => label}), :invalid_label)
      assert snapshot() == before
    end

    # A missing label key is the same refusal.
    assert refusal(action(actor, :rename, %{"id" => key}), :invalid_label)
    assert snapshot() == before

    # An unknown credential id refuses independently of the label.
    assert refusal(
             action(actor, :rename, %{"id" => Ash.UUID.generate(), "label" => "New"}),
             :unknown_credential
           )

    assert snapshot() == before

    assert passkeys(actor.id) == %{key => "Test passkey"}
    assert Security.recent?(actor)
  end

  test "rename updates exactly one label and keeps elevation, sessions and audit" do
    actor = elevate(user())
    proving = passkey_id(actor, actor.__metadata__.test_authenticator)
    second = register(actor)
    second_id = passkey_id(actor, second)
    audit_before = Ledger.read!(AdminEvent)

    assert {:ok, %{updated: true}} =
             action(actor, :rename, %{"id" => second_id, "label" => "Backup key"})

    assert passkeys(actor.id) == %{proving => "Test passkey", second_id => "Backup key"}
    assert Security.recent?(actor)
    assert Security.passkey_verified?(Security.jti(actor), actor.id)
    assert {:ok, _} = Login.present(Security.jti(actor), actor.id)
    assert Ledger.read!(AdminEvent) == audit_before
  end

  test "renaming the proving credential preserves elevation" do
    actor = elevate(user())
    proving = passkey_id(actor, actor.__metadata__.test_authenticator)

    assert {:ok, %{updated: true}} =
             action(actor, :rename, %{"id" => proving, "label" => "YubiKey 5"})

    assert %{proving => "YubiKey 5"} == passkeys(actor.id)
    assert Security.recent?(actor)
    assert Security.passkey_verified?(Security.jti(actor), actor.id)
  end

  test "removing a non-proving credential keeps MFA, elevation and every session" do
    actor = elevate(user())
    proving = passkey_id(actor, actor.__metadata__.test_authenticator)
    spare = register(actor)
    spare_id = passkey_id(actor, spare)
    assert map_size(passkeys(actor.id)) == 2

    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => spare_id})
    assert Map.keys(passkeys(actor.id)) == [proving]
    assert Security.current(actor.id).mfa_enabled
    assert Security.recent?(actor)
    assert {:ok, _} = Login.present(Security.jti(actor), actor.id)

    assert [%{target_id: ^spare_id}] =
             for(event <- Ledger.read!(AdminEvent), event.kind == :passkey_remove, do: event)
  end

  test "removing the proving credential ends elevation immediately (ADR-0065)" do
    actor = elevate(user(true))
    proving = passkey_id(actor, actor.__metadata__.test_authenticator)
    spare = register(actor)
    spare_id = passkey_id(actor, spare)
    assert Security.recent?(actor)
    assert Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))

    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => proving})

    # Elevation and this login's retained passkey receipt end at once, while
    # the ordinary stored login remains valid.
    refute Security.recent?(actor)
    refute Security.passkey_verified?(Security.jti(actor), actor.id)
    assert {:ok, _} = Login.present(Security.jti(actor), actor.id)
    refute Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))
    assert Security.current(actor.id).mfa_enabled

    # The removed authenticator cannot re-elevate; the surviving one can.
    assert {:ok, challenge} = action(actor, :begin_verify)

    assert {:ok, %{error: _}} =
             action(
               actor,
               :finish_verify,
               assertion(challenge, actor.__metadata__.test_authenticator)
             )

    assert {:ok, %{verified: true}} = verify(actor, spare)
    assert Security.recent?(actor)
    assert Map.keys(passkeys(actor.id)) == [spare_id]
  end

  test "second-to-last removal keeps MFA; last removal disables MFA and revokes all tokens" do
    actor = elevate(user())
    generation = Security.current(actor.id).mfa_generation
    spare = register(actor)
    spare_id = passkey_id(actor, spare)
    {other, other_token} = login(actor)
    other_jti = Security.jti(other)
    assert other_token
    # The second login has no elevation receipt; its stored token is alive.
    assert {:ok, _} = Login.token_present(other_jti, actor.id)

    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => spare_id})
    assert Security.current(actor.id).mfa_enabled
    assert {:ok, _} = Login.token_present(other_jti, actor.id)
    assert length(Map.keys(passkeys(actor.id))) == 1

    # Last removal requires current elevation, which removing the spare preserved.
    [last_id] = Map.keys(passkeys(actor.id))
    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => last_id})

    current = Security.current(actor.id)
    refute current.mfa_enabled
    assert current.mfa_generation == generation + 1
    assert :error = Login.present(Security.jti(actor), actor.id)
    assert :error = Login.present(other_jti, actor.id)

    # A revoked login cannot re-enroll, and no live token remains in the store.
    assert {:error, _} = action(actor, :begin_register)

    assert Enum.empty?(
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT jti FROM tokens WHERE subject = $1 AND purpose != 'revocation'",
               ["user?id=" <> actor.id],
               log: false
             ).rows
           )
  end

  test "locked elevation refuses rename and remove with unchanged inventory" do
    actor = elevate(user())
    key = passkey_id(actor, actor.__metadata__.test_authenticator)
    assert {:ok, %{locked: true}} = action(actor, :lock)
    before = snapshot()

    assert {:error, _} = action(actor, :rename, %{"id" => key, "label" => "New"})
    assert {:error, _} = action(actor, :remove, %{"id" => key})
    assert snapshot() == before
    assert passkeys(actor.id) == %{key => "Test passkey"}
  end

  test "stale actor after sign-out refuses credential changes with unchanged inventory" do
    actor = elevate(user())
    key = passkey_id(actor, actor.__metadata__.test_authenticator)

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        actor.__metadata__.token
      )

    before = snapshot()
    assert {:error, _} = action(actor, :rename, %{"id" => key, "label" => "New"})
    assert {:error, _} = action(actor, :remove, %{"id" => key})
    assert {:error, _} = action(actor, :lock)
    assert snapshot() == before
  end

  test "administrator last-passkey removal is refused until a second passkey exists" do
    admin = elevate(user(true))
    key = passkey_id(admin, admin.__metadata__.test_authenticator)
    before = snapshot()
    assert {:error, _} = action(admin, :remove, %{"id" => key})
    assert snapshot() == before
    assert passkeys(admin.id) == %{key => "Test passkey"}
    assert Security.recent?(admin)

    spare = register(admin)
    spare_id = passkey_id(admin, spare)
    assert {:ok, %{updated: true}} = action(admin, :remove, %{"id" => spare_id})
    assert {:error, _} = action(admin, :remove, %{"id" => key})
    assert Security.recent?(admin)
    assert passkeys(admin.id) == %{key => "Test passkey"}
  end

  test "registration refuses beyond ten live credentials on begin and finish" do
    actor = elevate(user())
    for _ <- 1..8, do: seed_passkey(actor)
    assert map_size(passkeys(actor.id)) == 9

    {:ok, first} = action(actor, :begin_register)
    {:ok, second} = action(actor, :begin_register)

    assert {:ok, %{registered: true}} =
             action(actor, :finish_register, registration(first, authenticator()))

    assert map_size(passkeys(actor.id)) == 10

    # begin_register now refuses without creating a challenge.
    begin_before = snapshot()
    assert {:error, _} = action(actor, :begin_register)
    assert snapshot() == begin_before

    # The pre-limit challenge refuses at finish and is not consumed.
    assert {:error, _} =
             action(actor, :finish_register, registration(second, authenticator()))

    assert map_size(passkeys(actor.id)) == 10
    assert [%{consumed_at: nil}] = Ledger.read!(PasskeyChallenge, id: second.id)

    # Dropping back under the limit makes the retained challenge usable again.
    proving = passkey_id(actor, actor.__metadata__.test_authenticator)
    [seeded | _] = Map.keys(passkeys(actor.id)) -- [proving]
    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => seeded})
    assert map_size(passkeys(actor.id)) == 9

    assert {:ok, %{registered: true}} =
             action(actor, :finish_register, registration(second, authenticator()))

    assert map_size(passkeys(actor.id)) == 10
    assert [%{consumed_at: %DateTime{}}] = Ledger.read!(PasskeyChallenge, id: second.id)
  end

  test "a failed registration never enables MFA and consumes its challenge" do
    {actor, _} = login(user())
    {:ok, challenge} = action(actor, :begin_register)

    assert {:ok, %{error: _}} =
             action(
               actor,
               :finish_register,
               registration(challenge, authenticator(), origin: "https://wrong.example")
             )

    refute Security.current(actor.id).mfa_enabled
    assert [%{consumed_at: %DateTime{}}] = Ledger.read!(PasskeyChallenge, id: challenge.id)
    assert {:error, _} = action(actor, :finish_register, registration(challenge, authenticator()))
  end
end
