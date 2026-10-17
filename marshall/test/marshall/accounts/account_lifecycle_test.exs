defmodule Marshall.Accounts.AccountLifecycleTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.{AdminEvent, User, Security, UserDeletion, DeleteUserMachines}
  alias Marshall.Compute.{Ledger, Operation, Host, Outcomes, Reservation}
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Teams
  alias Marshall.Teams.{TeamMember, Transfer}

  setup do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})

    %{
      admin: Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true)),
      user: Marshall.PasskeyFixture.user()
    }
  end

  test "reset requires another verified administrator and blocks old sessions", %{
    admin: admin,
    user: user
  } do
    actor = Marshall.PasskeyFixture.elevate(user)
    assert {:error, _} = command(:reset_mfa, %{user_id: user.id}, user)
    assert {:error, _} = command(:reset_mfa, %{user_id: admin.id}, admin)
    assert {:ok, %{reset: true}} = command(:reset_mfa, %{user_id: user.id}, admin)
    refute Security.recent?(actor)
    assert Security.current(user.id).mfa_reset_required
    {new_login, _} = Marshall.PasskeyFixture.login(Security.current(user.id))
    assert {:ok, _} = Marshall.Accounts.Login.present(Security.jti(new_login), user.id)
    refute Security.passkey_verified?(Security.jti(new_login), user.id)
    key = Marshall.PasskeyFixture.register(new_login)
    assert {:ok, %{verified: true}} = Marshall.PasskeyFixture.verify(new_login, key)
    assert Security.passkey_verified?(Security.jti(new_login), user.id)
  end

  test "invitations preserve verification and email eligibility", %{admin: admin} do
    email = "invited-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
    assert {:ok, %{invited: true}} = command(:invite_user, %{email: email}, admin)
    assert [] == Enum.filter(Ash.read!(User, authorize?: false), &(to_string(&1.email) == email))
    assert [_] = Ledger.read!(Marshall.Accounts.AuthEmail)
    assert {:ok, %{invited: true}} = command(:invite_user, %{email: "person@example.org"}, admin)
    assert {:ok, %{invited: true}} = command(:invite_user, %{email: "root@example.org"}, admin)
    assert {:error, _} = command(:invite_user, %{email: "person@bad_domain.org"}, admin)
  end

  test "deletion rejects self and mismatched confirmation and is idempotent", %{
    admin: admin,
    user: user
  } do
    assert {:error, _} =
             command(
               :delete_user,
               %{user_id: admin.id, confirmation: to_string(admin.email)},
               admin
             )

    assert {:error, _} = command(:delete_user, %{user_id: user.id, confirmation: "wrong"}, admin)
    args = %{user_id: user.id, confirmation: to_string(user.email)}
    assert {:ok, result} = command(:delete_user, args, admin)
    assert {:ok, ^result} = command(:delete_user, args, admin)
    refute Cedar.allowed?(user, "provision", Cedar.entity("ControlPlane", "marshall"))

    assert {:error, _} =
             command(:set_administrator, %{user_id: user.id, administrator: true}, admin)

    assert {:ok, %{complete: true}} = advance(result.id)
    assert [%{completed_at: %DateTime{}}] = Ledger.read!(UserDeletion, id: result.id)
  end

  test "owned VMs are queued for physical deletion, shared-only VMs remain", %{
    admin: admin,
    user: user
  } do
    host = Marshall.ComputeFixtures.host_fixture()

    {:ok, owned} =
      Marshall.Compute.provision(Marshall.ComputeFixtures.request(%{profile: :customer}),
        actor: user
      )

    {:ok, other} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: admin)

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: other.id,
                 email: to_string(user.email),
                 role: :manager,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: admin
             )

    {:ok, deletion} =
      command(:delete_user, %{user_id: user.id, confirmation: to_string(user.email)}, admin)

    assert {:ok, %{complete: false, remaining: 1}} = advance(deletion.id)
    operations = Ledger.read!(Operation, vm_id: owned.id)
    operation = Enum.find(operations, &(&1.kind == :delete))
    assert operation
    assert [%{disk_held: true}] = Ledger.read!(Reservation, vm_id: owned.id)
    assert {:ok, %{complete: false}} = advance(deletion.id)
    assert 1 == Enum.count(Ledger.read!(Operation, vm_id: owned.id), &(&1.kind == :delete))

    assert [%{desired_state: :running}] =
             Ledger.read!(Marshall.Compute.VirtualMachine, id: other.id)

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: owned.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :deleted,
      compute_empty: true,
      disk_present: false,
      cleanup_complete: true,
      reason: :none
    }

    {:ok, outcome} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(outcome))

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, host.host.id)
               Outcomes.ingest_locked!(host.host.id, [outcome])
             end)

    assert {:ok, %{complete: true, remaining: 0}} = advance(deletion.id)
  end

  # @cc [owner:ghuntley,label:verification;persistence] retirement-refusal-preserves-guest
  # A real team-owner refusal after guest retirement has begun MUST roll back
  # the GuestAccount marker and audit along with the User and deletion receipt.
  test "retirement rejects an active team owner with a stable reason", %{
    admin: admin,
    user: user
  } do
    {:ok, _team} = create_team(user)

    assert {:ok, account} =
             Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(user.id) end)

    before = Ledger.read!(Marshall.Accounts.GuestAccount, id: account.id)

    versions =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM account_guest_accounts_versions WHERE version_source_id = $1",
        [Ecto.UUID.dump!(account.id)],
        log: false
      ).rows

    assert {:error, %Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: :team_owner}]}} =
             command(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               admin
             )

    assert Security.current(user.id).deleted_at == nil
    assert [] == Ledger.read!(UserDeletion, user_id: user.id)
    assert Ledger.read!(Marshall.Accounts.GuestAccount, id: account.id) == before

    assert Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT count(*) FROM account_guest_accounts_versions WHERE version_source_id = $1",
             [Ecto.UUID.dump!(account.id)],
             log: false
           ).rows == versions
  end

  test "retirement archives non-owner memberships and cancels pending transfers", %{
    admin: admin,
    user: user
  } do
    owner = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)
    add_member(team.id, user, owner)
    {:ok, transfer} = Marshall.Teams.Coordinator.offer(team.id, to_string(user.email), owner)

    assert {:ok, deletion} =
             command(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               admin
             )

    assert [] == Ledger.read!(TeamMember, team_id: team.id, user_id: user.id)
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(TeamMember, user_id: user.id)
    assert [%{state: :cancelled}] = Ledger.read!(Transfer, id: transfer.id)

    assert Enum.any?(
             Ledger.read!(AdminEvent, target_id: team.id),
             &(&1.kind == :team_membership_change and &1.actor_id == admin.id)
           )

    assert Enum.any?(
             Ledger.read!(AdminEvent, target_id: transfer.id),
             &(&1.kind == :team_transfer_cancel and &1.actor_id == admin.id)
           )

    assert {:ok, %{complete: true}} = advance(deletion.id)
  end

  test "retirement archives user-owned integrations without removing team integrations", %{
    admin: admin,
    user: user
  } do
    owner = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)
    add_member(team.id, user, owner)

    {:ok, personal} = integration(user, "personal-retirement", nil)
    {:ok, shared} = integration(owner, "team-retirement", team.id)

    assert {:ok, _} =
             command(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               admin
             )

    assert [] == Ledger.read!(Marshall.Galileo.Integration, id: personal.id)

    assert [%{archived_at: %DateTime{}}] =
             Ledger.history!(Marshall.Galileo.Integration, id: personal.id)

    assert [%{id: id}] = Ledger.read!(Marshall.Galileo.Integration, id: shared.id)
    assert id == shared.id
  end

  test "old emailed tokens cannot resurrect identity; new registration has a new UUID", %{
    admin: admin,
    user: user
  } do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, old_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(
        strategy,
        to_string(user.email)
      )

    assert {:ok, _} =
             command(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               admin
             )

    assert {:error, _} = sign_in(old_token)

    {:ok, new_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(
        strategy,
        to_string(user.email)
      )

    assert {:ok, replacement} = sign_in(new_token)
    refute replacement.id == user.id
    refute replacement.administrator
    refute replacement.mfa_enabled
  end

  test "administrative lifecycle outcomes emit structured events after commit", %{
    admin: admin,
    user: user
  } do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :user_id, :actor_id]],
        fn ->
          email = "invited-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
          assert {:ok, %{invited: true}} = command(:invite_user, %{email: email}, admin)
          assert {:ok, %{reset: true}} = command(:reset_mfa, %{user_id: user.id}, admin)

          assert {:ok, _} =
                   command(
                     :delete_user,
                     %{user_id: user.id, confirmation: to_string(user.email)},
                     admin
                   )
        end
      )

    assert logs =~ "Account invited"
    assert logs =~ "Account MFA reset"
    assert logs =~ "Account deleted"
    assert logs =~ "user_id=" <> user.id
    assert logs =~ "actor_id=" <> admin.id
  end

  test "retired-token rejection emits a structured event only for retired tokens", %{
    admin: admin,
    user: user
  } do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, old_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(
        strategy,
        to_string(user.email)
      )

    assert {:ok, _} =
             command(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               admin
             )

    {:ok, new_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(
        strategy,
        to_string(user.email)
      )

    old_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: old_level) end)

    fresh =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = sign_in(new_token)
      end)

    refute fresh =~ "Retired-account authentication token rejected"

    retired =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} = sign_in(old_token)
      end)

    assert retired =~ "Retired-account authentication token rejected"
  end

  defp command(action, args, actor),
    do: User |> Ash.ActionInput.for_action(action, args, actor: actor) |> Ash.run_action()

  defp advance(id),
    do:
      DeleteUserMachines.run(%{arguments: %{primary_key: %{"id" => id}}}, [], %{
        actor: SystemActor.compute()
      })

  defp sign_in(token),
    do:
      User
      |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
        context: %{private: %{ash_authentication?: true}}
      )
      |> Ash.create()

  @spec create_team(User.t()) :: {:ok, Marshall.Teams.Team.t()} | {:error, term()}
  defp create_team(actor) do
    Teams.create_team(
      %{
        name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  @spec add_member(String.t(), User.t(), User.t()) :: :ok
  defp add_member(team_id, member, owner) do
    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team_id,
                 email: to_string(member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  defp integration(actor, name, team_id) do
    Marshall.Galileo.configure_integration(
      %{
        name: name,
        target: "https://api.example.test",
        headers: [],
        peer: false,
        team_id: team_id,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end
end
