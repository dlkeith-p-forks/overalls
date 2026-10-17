defmodule Marshall.Accounts.AccountLifecycleHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.{AdminEvent, AuthEmail, Passkey, Security, User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, Reservation, VirtualMachine}
  alias Marshall.ComputeFixtures, as: Fixtures
  require Ash.Query

  @typep generation :: {boolean(), [:ordinary | :wrong_email | :self], pos_integer()}
  @typep history :: %{identities: [String.t()], tokens: [String.t()], receipts: [String.t()]}
  @typep fixture :: %{
           admin: User.t(),
           outsider: User.t(),
           survivor: VirtualMachine.t(),
           host_id: String.t(),
           team_id: String.t(),
           email: String.t()
         }

  @tag timeout: 120_000
  # @cc [owner:ghuntley,label:verification;security] retirement-generation-oracle
  # Histories MUST compare independent identity generations and pinned receipt
  # sets after every refused/retried action. A replacement MUST appear while old
  # cleanup still holds disk, inherit no authority, and survive old-UUID cleanup.
  # Synthetic outcomes prove coordinator fencing only, never native reclamation.
  property "same-email generations cannot inherit retired authority or redirect cleanup" do
    check all(
            generations <-
              list_of(
                tuple({
                  boolean(),
                  list_of(member_of([:ordinary, :wrong_email, :self]),
                    min_length: 1,
                    max_length: 5
                  ),
                  integer(1..3)
                }),
                min_length: 2,
                max_length: 3
              ),
            max_runs: 12
          ) do
      fixture = fixture()

      assert {:ok, %{invited: true}} =
               command(:invite_user, %{email: fixture.email}, fixture.admin)

      assert active_email(fixture.email) == []

      assert [mail] =
               AuthEmail
               |> Ash.Query.filter(recipient_fingerprint == ^fingerprint(fixture.email))
               |> Ash.read!(actor: SystemActor.compute())

      payload = Ash.load!(mail, :payload, actor: SystemActor.compute()).payload
      assert payload["email"] == fixture.email
      assert {:ok, first} = sign_in(payload["token"])
      assert_fresh(first)

      {last, history} =
        Enum.reduce(generations, {first, %{identities: [], tokens: [], receipts: []}}, fn
          generation, {current, history} ->
            advance_generation(generation, current, history, fixture)
        end)

      assert active_email(fixture.email) == [last.id]
      assert Enum.uniq([last.id | history.identities]) == [last.id | history.identities]

      assert Enum.sort(Enum.map(Ledger.read!(UserDeletion, email: fixture.email), & &1.id)) ==
               Enum.sort(history.receipts)

      for id <- history.identities do
        assert %User{deleted_at: %DateTime{}, administrator: false} = Security.current(id)
        assert [] == Ledger.read!(VirtualMachine, owner_id: id)
      end

      assert_fresh(last)
      assert_survivor(fixture)
    end
  end

  @spec advance_generation(generation(), User.t(), history(), fixture()) :: {User.t(), history()}
  defp advance_generation({promote?, refusals, retries}, user, history, fixture) do
    if promote?,
      do:
        assert(
          {:ok, _} =
            command(:set_administrator, %{user_id: user.id, administrator: true}, fixture.admin)
        )

    actor = Marshall.PasskeyFixture.elevate(Security.current(user.id))

    assert [%{user_id: prior_id, sign_count: 0}] = Ledger.read!(Passkey, user_id: actor.id)
    assert prior_id == actor.id
    assert Security.current(actor.id).mfa_enabled
    assert Security.recent?(actor)

    assert {:ok, _} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: fixture.team_id,
                 email: fixture.email,
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: fixture.outsider
             )

    assert [%{role: :member}] =
             Ledger.read!(Marshall.Teams.TeamMember, team_id: fixture.team_id, user_id: actor.id)

    public_key =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    assert {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: actor)

    assert {:ok, grant} =
             Marshall.Access.set_access(
               %{
                 vm_id: fixture.survivor.id,
                 email: fixture.email,
                 role: :manager,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: fixture.outsider
             )

    Ledger.update!(hd(Ledger.read!(Host, id: fixture.host_id)), :report, %{
      reported_at: Ledger.now()
    })

    assert {:ok, owned} =
             Marshall.Compute.provision(Fixtures.request(%{profile: :customer, vcpu: 1}),
               actor: actor
             )

    stale = token(fixture.email)
    args = %{user_id: actor.id, confirmation: fixture.email}
    before = snapshot([actor.id, fixture.admin.id, fixture.outsider.id])

    for refusal <- [:ordinary, :wrong_email, :self] ++ refusals do
      case refusal do
        :ordinary ->
          assert {:error, %Ash.Error.Forbidden{}} = command(:delete_user, args, fixture.outsider)

        :wrong_email ->
          assert {:error,
                  %Ash.Error.Invalid{
                    errors: [%Marshall.Compute.Error{reason: :confirmation_mismatch}]
                  }} =
                   command(
                     :delete_user,
                     %{args | confirmation: "wrong@example.test"},
                     fixture.admin
                   )

        :self ->
          assert {:error,
                  %Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: :self_deletion}]}} =
                   command(
                     :delete_user,
                     %{user_id: fixture.admin.id, confirmation: to_string(fixture.admin.email)},
                     fixture.admin
                   )
      end

      assert snapshot([actor.id, fixture.admin.id, fixture.outsider.id]) == before
    end

    assert {:ok, receipt} = command(:delete_user, args, fixture.admin)
    assert :error = Marshall.Accounts.Login.token_present(Security.jti(actor), actor.id)
    refute Security.recent?(actor)
    assert {:error, _} = Marshall.Compute.get_vm(%{vm_id: owned.id}, actor: actor)
    assert {:error, _} = Marshall.Compute.get_vm(%{vm_id: fixture.survivor.id}, actor: actor)

    for old_token <- [stale | history.tokens], do: assert({:error, _} = sign_in(old_token))
    assert {:ok, replacement} = sign_in(token(String.upcase(fixture.email)))
    refute replacement.id in [actor.id | history.identities]
    assert_fresh(replacement)
    assert {:error, _} = Marshall.Compute.get_vm(%{vm_id: owned.id}, actor: replacement)

    assert {:error, _} =
             Marshall.Compute.get_vm(%{vm_id: fixture.survivor.id}, actor: replacement)

    for _ <- 1..retries do
      assert {:ok, ^receipt} = command(:delete_user, args, fixture.admin)
      assert {:ok, %{complete: false, remaining: 1}} = cleanup(receipt.id)
      assert [%{disk_held: true}] = Ledger.read!(Reservation, vm_id: owned.id)
      assert [%{completed_at: nil, user_id: old_id}] = Ledger.read!(UserDeletion, id: receipt.id)
      assert old_id == actor.id
      assert_fresh(replacement)
      assert_survivor(fixture)
    end

    assert [operation] =
             Enum.filter(Ledger.read!(Operation, vm_id: owned.id), &(&1.kind == :delete))

    assert Enum.count(Ledger.read!(AdminEvent, target_id: actor.id), &(&1.kind == :user_delete)) ==
             1

    assert [%{id: key_id, archived_at: %DateTime{}}] =
             Ledger.history!(Marshall.SSH.Key, user_id: actor.id)

    assert key_id == key.id

    assert [%{archived_at: %DateTime{}}] =
             Ledger.history!(Marshall.Access.Grant, user_id: actor.id)

    assert grant.vm_id == fixture.survivor.id
    assert [] == Ledger.read!(Passkey, user_id: actor.id)
    reclaim(operation, owned.host_id)

    for _ <- 1..retries do
      assert {:ok, %{complete: true}} = cleanup(receipt.id)
      assert {:ok, ^receipt} = command(:delete_user, args, fixture.admin)
      assert [] == Ledger.read!(VirtualMachine, owner_id: actor.id)
      assert [%{disk_held: false}] = Ledger.read!(Reservation, vm_id: owned.id)
      assert active_email(fixture.email) == [replacement.id]
      assert_fresh(replacement)
      assert_survivor(fixture)
    end

    {replacement,
     %{
       identities: [actor.id | history.identities],
       tokens: [stale | history.tokens],
       receipts: [receipt.id | history.receipts]
     }}
  end

  @spec fixture() :: fixture()
  defp fixture do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))
    outsider = Fixtures.user()
    host = Fixtures.host_fixture()

    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "retire-" <> binary_part(Ash.UUID.generate(), 0, 12),
          idempotency_key: Ash.UUID.generate()
        },
        actor: outsider
      )

    assert {:ok, survivor} =
             Marshall.Compute.provision(Fixtures.request(%{profile: :oss, vcpu: 1}),
               actor: outsider
             )

    %{
      admin: admin,
      outsider: outsider,
      survivor: survivor,
      host_id: host.host.id,
      team_id: team.id,
      email: "history-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
    }
  end

  @spec assert_fresh(User.t()) :: :ok
  defp assert_fresh(user) do
    current = Security.current(user.id)
    assert current.deleted_at == nil
    refute current.administrator
    refute current.mfa_enabled
    assert current.mfa_generation == 0

    for resource <- [Passkey, Marshall.SSH.Key, Marshall.Access.Grant, Marshall.Teams.TeamMember],
        do: assert([] == Ledger.read!(resource, user_id: user.id))

    assert [] == Ledger.read!(VirtualMachine, owner_id: user.id)
    :ok
  end

  @spec assert_survivor(fixture()) :: :ok
  defp assert_survivor(fixture) do
    assert [%{desired_state: :running, owner_id: owner}] =
             Ledger.read!(VirtualMachine, id: fixture.survivor.id)

    assert owner == fixture.outsider.id

    assert Enum.map(Ledger.read!(Operation, vm_id: fixture.survivor.id), & &1.kind) == [
             :provision
           ]

    :ok
  end

  # Full persisted projections include refused self-deletion's administrator,
  # existing authority values, retained rows and versions; IDs alone miss changes.
  @spec snapshot([String.t()]) :: %{atom() => [map()]}
  defp snapshot(ids) do
    users = Enum.map(ids, &Security.current/1)

    vms =
      VirtualMachine
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(owner_id in ^ids)
      |> Ash.read!()

    vm_ids = Enum.map(vms, & &1.id)

    %{
      users:
        project(users, [
          :id,
          :email,
          :administrator,
          :mfa_enabled,
          :mfa_generation,
          :mfa_reset_required,
          :deleted_at
        ]),
      tokens: token_inventory(ids),
      machines:
        project(vms, [
          :id,
          :owner_id,
          :desired_state,
          :observed_state,
          :generation,
          :current_placement_id,
          :archived_at
        ]),
      reservations:
        project(read_in(Reservation, :vm_id, vm_ids), [
          :id,
          :vm_id,
          :placement_id,
          :compute_held,
          :disk_held,
          :startup_compute_held,
          :startup_disk_held,
          :temporary_disk_bytes,
          :pending_disk_bytes,
          :vcpu,
          :memory_bytes,
          :disk_bytes
        ]),
      operations:
        project(read_in(Operation, :vm_id, vm_ids), [
          :id,
          :vm_id,
          :kind,
          :status,
          :generation,
          :placement_id,
          :execution_epoch,
          :requested_by_id
        ]),
      deletions:
        project(read_in(UserDeletion, :user_id, ids), [
          :id,
          :user_id,
          :requested_by_id,
          :email,
          :remaining,
          :blocked,
          :completed_at
        ]),
      audit: project(Ledger.read!(AdminEvent), [:id, :actor_id, :target_id, :kind, :inserted_at]),
      passkeys: project(read_in(Passkey, :user_id, ids), [:id, :user_id, :sign_count, :label]),
      proofs:
        project(read_in(Marshall.Accounts.Verification, :user_id, ids), [
          :id,
          :user_id,
          :generation,
          :verified_at,
          :elevated_until,
          :credential_id
        ]),
      keys:
        project(Ledger.history!(Marshall.SSH.Key, []), [:id, :user_id, :fingerprint, :archived_at]),
      grants:
        project(Ledger.history!(Marshall.Access.Grant, []), [
          :id,
          :user_id,
          :vm_id,
          :role,
          :archived_at
        ]),
      memberships:
        project(Ledger.history!(Marshall.Teams.TeamMember, []), [
          :id,
          :team_id,
          :user_id,
          :role,
          :archived_at
        ]),
      key_versions:
        project(Ledger.read!(Marshall.SSH.Key.Version), [
          :id,
          :version_source_id,
          :version_action_name,
          :changes
        ]),
      grant_versions:
        project(Ledger.read!(Marshall.Access.Grant.Version), [
          :id,
          :version_source_id,
          :version_action_name,
          :changes
        ])
    }
  end

  @spec read_in(module(), atom(), [String.t()]) :: [Ash.Resource.Record.t()]
  defp read_in(resource, key, ids),
    do:
      resource |> Ash.Query.filter(^[{key, [in: ids]}]) |> Ash.read!(actor: SystemActor.compute())

  @spec token_inventory([String.t()]) :: [map()]
  defp token_inventory(ids) do
    subjects = Enum.map(ids, &("user?id=" <> &1))

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT md5(jti), subject, purpose, expires_at, created_at, updated_at FROM tokens WHERE subject = ANY($1) ORDER BY jti",
        [subjects],
        log: false
      )

    Enum.map(rows, fn [identity, subject, purpose, expiry, created, updated]
                      when is_binary(identity) and is_binary(subject) and is_binary(purpose) ->
      %{
        identity: identity,
        subject: subject,
        purpose: purpose,
        expiry: expiry,
        created: created,
        updated: updated
      }
    end)
  end

  @spec project([map()], [atom()]) :: [map()]
  defp project(rows, fields), do: rows |> Enum.map(&Map.take(&1, fields)) |> Enum.sort_by(& &1.id)

  @spec active_email(String.t()) :: [String.t()]
  defp active_email(email),
    do:
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(email == ^email and is_nil(deleted_at))
      |> Ash.read!()
      |> Enum.map(& &1.id)

  @spec fingerprint(String.t()) :: String.t()
  defp fingerprint(email),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:marshall, :token_signing_secret),
        String.downcase(email)
      )
      |> Base.encode16(case: :lower)

  @spec token(String.t()) :: String.t()
  defp token(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    token
  end

  @spec sign_in(String.t()) :: {:ok, User.t()} | {:error, term()}
  defp sign_in(token),
    do:
      User
      |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
        context: %{private: %{ash_authentication?: true}}
      )
      |> Ash.create()

  @spec command(atom(), map(), User.t()) :: {:ok, map()} | {:error, term()}
  defp command(action, args, actor),
    do: User |> Ash.ActionInput.for_action(action, args, actor: actor) |> Ash.run_action()

  @spec cleanup(String.t()) :: {:ok, map()} | {:error, term()}
  defp cleanup(id),
    do:
      Marshall.Accounts.DeleteUserMachines.run(%{arguments: %{primary_key: %{"id" => id}}}, [], %{
        actor: SystemActor.compute()
      })

  @spec reclaim(Operation.t(), String.t()) :: :ok
  defp reclaim(operation, host_id) do
    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
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
               Ledger.lock!(Host, host_id)
               Outcomes.ingest_locked!(host_id, [outcome])
             end)

    :ok
  end
end
