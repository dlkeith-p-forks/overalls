defmodule Marshall.Accounts.GuestIdentityHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.{GuestAccount, GuestAccounts, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Credentials
  alias Marshall.SSH.GuestAccess
  require Ash.Query

  setup do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})

    %{admin: Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))}
  end

  # @cc [owner:ghuntley,label:verification;security] fresh-guest-incarnation-oracle
  # Real retirement and verified same-email registration MUST yield a distinct
  # usable guest account without changing any prior username or UID reservation.
  # Database allocation evidence MUST NOT be presented as native home isolation.
  @tag :hegel
  test "same-email generations allocate distinct stable guest identities", %{admin: admin} do
    check all(generations <- integer(2..4), max_runs: 6) do
      email = "again-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
      original = register!(email)
      assert {:ok, first} = Ledger.transaction(fn -> GuestAccounts.ensure!(original.id) end)

      Enum.reduce(1..generations, {original, [first]}, fn _, {old_user, prior} ->
        retire!(old_user, admin)
        fresh = register!(email)
        refute fresh.id == old_user.id
        refute fresh.administrator
        assert [] == Ledger.read!(Marshall.SSH.Key, user_id: fresh.id)
        assert [] == Ledger.read!(Marshall.Access.Grant, user_id: fresh.id)
        assert [] == Ledger.read!(Marshall.Teams.TeamMember, user_id: fresh.id)

        assert {:ok, next} = Ledger.transaction(fn -> GuestAccounts.ensure!(fresh.id) end)
        assert {:ok, same} = Ledger.transaction(fn -> GuestAccounts.ensure!(fresh.id) end)
        assert next.id == same.id
        assert next.username == same.username
        assert next.uid == same.uid

        for old <- prior do
          refute old.username == next.username
          refute old.uid == next.uid
          assert [preserved] = Ledger.read!(GuestAccount, id: old.id)

          assert {preserved.user_id, preserved.username, preserved.uid} ==
                   {old.user_id, old.username, old.uid}
        end

        {fresh, [next | prior]}
      end)
    end
  end

  test "a fresh explicitly shared writer cannot prevent the surviving owner's roster", %{
    admin: admin
  } do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, credential} = Credentials.rotate(fixture.vm.host_id, 3600)
    token = credential.id <> "." <> credential.secret

    binding = Marshall.TerminalFixtures.roster_binding(fixture.vm)

    email = "shared-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
    original = register!(email)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, original, :operator)
    assert {:ok, %{accounts: before}} = GuestAccess.roster(token, binding)
    assert length(before) == 2
    [old_account] = Ledger.read!(GuestAccount, user_id: original.id)
    [owner_account] = Ledger.read!(GuestAccount, user_id: fixture.owner.id)

    retire!(original, admin)
    fresh = register!(email)
    assert {:ok, %{accounts: [surviving]}} = GuestAccess.roster(token, binding)
    assert surviving == %{username: owner_account.username, uid: owner_account.uid}
    assert [] == Ledger.read!(GuestAccount, user_id: fresh.id)

    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, fresh, :operator)
    assert {:ok, %{accounts: after_share}} = GuestAccess.roster(token, binding)
    assert length(after_share) == 2
    assert surviving in after_share
    refute %{username: old_account.username, uid: old_account.uid} in after_share

    [replacement] = Ledger.read!(GuestAccount, user_id: fresh.id)
    assert %{username: replacement.username, uid: replacement.uid} in after_share
    refute replacement.username == old_account.username
    refute replacement.uid == old_account.uid
  end

  test "SSH account discovery reports the fresh allocated name", %{admin: admin} do
    email = "proof-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
    original = register!(email)
    assert {:ok, old} = Ledger.transaction(fn -> GuestAccounts.ensure!(original.id) end)
    retire!(original, admin)
    fresh = register!(email)
    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 18::256>>)
    assert {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: fresh)
    {gateway_token, _} = Marshall.SSH.Token.issue(:gateway)

    assert {:ok, _} =
             Marshall.SSH.configure_gateway(
               %{name: "fresh-identity-proof", token: gateway_token},
               actor: SystemActor.compute()
             )

    assert {:ok, session} =
             Marshall.SSH.open_session(
               %{gateway_token: gateway_token, public_key: public_key},
               actor: SystemActor.compute()
             )

    {:ok, command} = OverallsProtocol.SSHCommand.parse("whoami")

    request = %{
      gateway_token: gateway_token,
      session_token: session.session_token,
      command: command |> Jason.encode!() |> Jason.decode!()
    }

    assert [] == Ledger.read!(GuestAccount, user_id: fresh.id)

    assert {:ok, %{result: %{guest_username: username, public_key: ^public_key}} = proof} =
             Marshall.SSH.execute(request, actor: SystemActor.compute())

    refute username == old.username
    assert [allocated] = Ledger.read!(GuestAccount, user_id: fresh.id)
    assert allocated.username == username
    versions = versions(allocated.id)
    assert [%{actor_kind: :user, actor_id: actor_id}] = versions
    assert actor_id == fresh.id
    assert {:ok, ^proof} = Marshall.SSH.execute(request, actor: SystemActor.compute())
    assert [allocated] == Ledger.read!(GuestAccount, user_id: fresh.id)
    assert versions == versions(allocated.id)

    retire!(fresh, admin)
    assert {:error, _} = Marshall.SSH.execute(request, actor: SystemActor.compute())
    assert [retired] = Ledger.read!(GuestAccount, user_id: fresh.id)
    assert %DateTime{} = retired.retired_at

    assert {retired.id, retired.username, retired.uid} ==
             {allocated.id, allocated.username, allocated.uid}

    assert length(versions(retired.id)) == length(versions) + 1
  end

  # @cc [owner:ghuntley,label:verification;security] fresh-team-rejoin-roster
  # Retired mailbox replacements MUST inherit no team membership or guest
  # identity. Explicit member rejoin MUST allocate a distinct identity, preserve
  # every surviving teammate and exclude all retired incarnations from the
  # complete boot roster. This database history MUST NOT claim native home proof.
  test "fresh same-email team rejoin preserves every surviving guest identity", %{admin: admin} do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    survivor = Marshall.ComputeFixtures.user()
    email = "team-again-#{binary_part(Ash.UUID.generate(), 0, 12)}@example.test"
    original = register!(email)

    assert {:ok, team} =
             Marshall.Teams.create_team(
               %{name: "identity-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
               actor: fixture.owner
             )

    for member <- [survivor, original], do: join!(team.id, member, fixture.owner)

    assert {:ok, vm} =
             Marshall.Compute.provision(
               Marshall.ComputeFixtures.request(%{team_id: team.id, profile: :oss, vcpu: 1}),
               actor: fixture.owner
             )

    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)
    {:ok, credential} = Credentials.rotate(vm.host_id, 3600)
    token = credential.id <> "." <> credential.secret

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch,
      "operation_id" => operation.id,
      "generation" => vm.generation
    }

    assert {:ok, %{accounts: initial}} = GuestAccess.roster(token, binding)
    [first] = Ledger.read!(GuestAccount, user_id: original.id)
    [owner_account] = Ledger.read!(GuestAccount, user_id: fixture.owner.id)
    [survivor_account] = Ledger.read!(GuestAccount, user_id: survivor.id)
    old_identity = %{username: first.username, uid: first.uid}

    survivors =
      MapSet.new([
        %{username: owner_account.username, uid: owner_account.uid},
        %{username: survivor_account.username, uid: survivor_account.uid}
      ])

    assert MapSet.new(initial) == MapSet.put(survivors, old_identity)

    Enum.reduce(1..2, {original, [first]}, fn _, {old_user, history} ->
      retire!(old_user, admin)
      fresh = register!(email)
      refute fresh.id == old_user.id
      assert [] == Ledger.read!(Marshall.Teams.TeamMember, user_id: fresh.id)
      assert [] == Ledger.read!(Marshall.Access.Grant, user_id: fresh.id)
      assert [] == Ledger.read!(GuestAccount, user_id: fresh.id)
      assert {:ok, %{accounts: before_rejoin}} = GuestAccess.roster(token, binding)
      assert MapSet.new(before_rejoin) == survivors
      refute Marshall.Access.Authorization.allowed?(vm, fresh, "write")

      join!(team.id, fresh, fixture.owner)
      assert Marshall.Access.Authorization.allowed?(vm, fresh, "write")
      refute Marshall.Access.Authorization.allowed?(vm, fresh, "manage")
      assert {:ok, %{accounts: after_rejoin}} = GuestAccess.roster(token, binding)
      assert [replacement] = Ledger.read!(GuestAccount, user_id: fresh.id)

      assert MapSet.new(after_rejoin) ==
               MapSet.put(survivors, %{username: replacement.username, uid: replacement.uid})

      for previous <- history do
        refute previous.username == replacement.username
        refute previous.uid == replacement.uid
        refute %{username: previous.username, uid: previous.uid} in after_rejoin
        assert [retired] = Ledger.read!(GuestAccount, id: previous.id)
        assert %DateTime{} = retired.retired_at

        assert {retired.id, retired.user_id, retired.username, retired.uid} ==
                 {previous.id, previous.user_id, previous.username, previous.uid}
      end

      assert {:ok, stable} = Ledger.transaction(fn -> GuestAccounts.ensure!(fresh.id) end)
      assert stable.id == replacement.id
      {fresh, [replacement | history]}
    end)
  end

  @spec versions(String.t()) :: [Ash.Resource.Record.t()]
  defp versions(id),
    do:
      GuestAccount.Version
      |> Ash.Query.filter(version_source_id == ^id)
      |> Ash.read!(authorize?: false)

  @spec register!(String.t()) :: User.t()
  defp register!(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    User
    |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.create!()
  end

  @spec join!(String.t(), User.t(), User.t()) :: :ok
  defp join!(team_id, member, owner) do
    assert {:ok, _} =
             Marshall.Teams.set_team_member(
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

  @spec retire!(User.t(), User.t()) :: :ok
  defp retire!(user, admin) do
    assert {:ok, %{deleting: true}} =
             User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               actor: admin
             )
             |> Ash.run_action()

    assert {:error, _} = Ledger.transaction(fn -> GuestAccounts.ensure!(user.id) end)
    :ok
  end
end
