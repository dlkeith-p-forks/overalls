defmodule Marshall.SSH.GuestRosterHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties

  alias Marshall.Accounts.{GuestAccount, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Credentials
  alias Marshall.SSH.GuestAccess
  require Ash.Query

  @moduletag timeout: 120_000

  setup do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})

    %{admin: Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))}
  end

  # @cc [owner:ghuntley,label:verification;security] roster-composition-independent-oracle
  # The served roster MUST equal an independently derived current-writer set with
  # exact persisted username/UID pairs: owner, unarchived grants and current team
  # members, each still active and freshly Cedar write-authorized. Retired or
  # revoked candidates MUST be excluded while their identities stay reserved;
  # versions MUST strictly increase and re-fetch MUST preserve allocations.
  property "generated owner, grant and team histories serve exactly the durable writer identities",
           %{admin: admin} do
    check all(
            team? <- boolean(),
            assignments <-
              list_of(
                tuple({
                  member_of([:unused, :operator, :viewer, :revoked]),
                  member_of([:none, :member, :admin]),
                  boolean()
                }),
                min_length: 1,
                max_length: 4
              ),
            max_runs: 6
          ) do
      {vm, token, binding} = vm_fixture(team?)
      owner = owner_of(vm)

      pool =
        for {grant_role, team_role, retiring?} <- assignments do
          %{
            user: Marshall.ComputeFixtures.user(),
            grant: grant_role,
            team: team_role,
            retiring?: retiring?
          }
        end

      for %{grant: role} = entry <- pool, role != :unused do
        granted = if role == :revoked, do: :operator, else: role
        assert {:ok, _} = grant(vm, owner, entry.user, granted)
      end

      if team? do
        for %{team: role} = entry <- pool, role != :none do
          join!(vm.team_id, entry.user, role, owner)
        end
      end

      expected1 = expected_writer_ids(vm)
      assert {:ok, %{version: v1, accounts: first}} = GuestAccess.roster(token, binding)
      assert_roster_exact(first, expected1)
      first_projection = identity_rows([vm.owner_id | Enum.map(pool, & &1.user.id)])

      for %{grant: :revoked} = entry <- pool do
        assert {:ok, _} = grant(vm, owner, entry.user, :revoked)
      end

      for %{retiring?: true} = entry <- pool, do: retire!(entry.user, admin)

      expected2 = expected_writer_ids(vm)
      assert {:ok, %{version: v2, accounts: second}} = GuestAccess.roster(token, binding)
      assert v2 > v1
      assert_roster_exact(second, expected2)

      retired_ids = MapSet.new(for %{user: user, retiring?: true} <- pool, do: user.id)

      for {user_id, _id, _name, _uid, retired_at} <-
            identity_rows([vm.owner_id | Enum.map(pool, & &1.user.id)]) do
        if MapSet.member?(retired_ids, user_id),
          do: assert(%DateTime{} = retired_at),
          else: assert(is_nil(retired_at))
      end

      # Retirement changes the durable marker while preserving each identity.
      assert Enum.map(
               identity_rows([vm.owner_id | Enum.map(pool, & &1.user.id)]),
               &Tuple.delete_at(&1, 4)
             ) ==
               Enum.map(first_projection, &Tuple.delete_at(&1, 4))

      for %{user: user} <- pool,
          user.id not in expected1,
          user.id not in expected2 do
        assert [] == Ledger.read!(GuestAccount, user_id: user.id)
      end

      assert {:ok, %{version: v3, accounts: stable}} = GuestAccess.roster(token, binding)
      assert v3 > v2
      assert stable == second

      assert Enum.map(
               identity_rows([vm.owner_id | Enum.map(pool, & &1.user.id)]),
               &Tuple.delete_at(&1, 4)
             ) ==
               Enum.map(first_projection, &Tuple.delete_at(&1, 4))
    end
  end

  # @cc [owner:ghuntley,label:verification;security] roster-candidate-bound-atomic
  # A roster with more than 512 deduped candidates MUST be denied atomically
  # with no identity allocation; exactly 512 candidates MUST be admitted with
  # unique durable identities, and later stable re-fetch MUST preserve them.
  test "candidate bound denies 513 atomically and admits exactly 512 with durable identities" do
    {vm, token, binding} = vm_fixture(false)
    owner = owner_of(vm)

    extras = for _ <- 1..512, do: Marshall.ComputeFixtures.user()

    for user <- extras do
      Ash.Seed.seed!(Marshall.Access.Grant, %{
        vm_id: vm.id,
        user_id: user.id,
        role: :operator,
        granted_by_id: owner.id
      })
    end

    involved = [vm.owner_id | Enum.map(extras, & &1.id)]

    assert {:error, :unauthorized} = GuestAccess.roster(token, binding)
    assert {:error, :unauthorized} = GuestAccess.roster(token, binding)
    assert [] == identity_rows(involved)

    [dropped | kept] = extras
    assert {:ok, _} = grant(vm, owner, dropped, :revoked)

    assert {:ok, %{accounts: first, version: v1}} = GuestAccess.roster(token, binding)
    assert length(first) == 512
    assert_roster_exact(first, [owner.id | Enum.map(kept, & &1.id)])

    assert {:ok, %{accounts: stable, version: v2}} = GuestAccess.roster(token, binding)
    assert v2 > v1
    assert stable == first
  end

  # @cc [owner:ghuntley,label:verification;recovery] roster-allocation-rollback-recovery
  # A roster fetch whose allocation batch refuses MUST roll back completely:
  # no partial identity rows and all prior identities unchanged. Refusal
  # consumes sequence values; another fetch under exhausted UID space MUST
  # refuse again. After the blocked writer is revoked, recovery MUST
  # serve exactly the preserved identities with an increased version.
  test "UID exhaustion rolls back the roster and recovery preserves identities" do
    {vm, token, binding} = vm_fixture(false)
    owner = owner_of(vm)

    assert {:ok, %{accounts: [owner_pair], version: v1}} = GuestAccess.roster(token, binding)
    assert_roster_exact([owner_pair], [owner.id])
    owner_projection = identity_rows([owner.id])

    local = "blocked" <> (Ash.UUID.generate() |> String.replace("-", "") |> binary_part(0, 8))
    blocked = Ash.Seed.seed!(User, %{email: local <> "@example.test"})
    assert {:ok, _} = grant(vm, owner, blocked, :operator)

    restart_sequence!(999_999)

    assert [[999_999]] ==
             Ecto.Adapters.SQL.query!(
               Marshall.Repo,
               "SELECT nextval('account_guest_uid_seq')",
               [],
               log: false
             ).rows

    assert {:error, :guest_identity_unavailable} = GuestAccess.roster(token, binding)
    assert identity_rows([owner.id]) == owner_projection
    assert [] == Ledger.read!(GuestAccount, user_id: blocked.id)

    # Exhaustion remains a closed refusal; rollback stays complete.
    assert {:error, :guest_identity_unavailable} = GuestAccess.roster(token, binding)
    assert identity_rows([owner.id]) == owner_projection
    assert [] == Ledger.read!(GuestAccount, user_id: blocked.id)

    assert {:ok, _} = grant(vm, owner, blocked, :revoked)

    assert {:ok, %{accounts: [recovered], version: v3}} = GuestAccess.roster(token, binding)
    assert v3 > v1
    assert recovered == owner_pair
    assert [] == Ledger.read!(GuestAccount, user_id: blocked.id)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] roster-batch-sorted-order-oracle
  # Returned account order MUST follow the batch allocator's sorted unique User
  # IDs, never grant/team discovery order; an ensure!/1 loop regression changes
  # this observable order and loses the canonical lock ordering guarantee.
  @spec assert_roster_exact([map()], [String.t()]) :: :ok
  defp assert_roster_exact(accounts, expected_ids) do
    rows =
      GuestAccount
      |> Ash.Query.filter(user_id in ^expected_ids)
      |> Ash.read!(actor: SystemActor.compute())

    assert length(rows) == length(expected_ids)
    assert Enum.all?(rows, &(is_nil(&1.retired_at) and &1.user_id in expected_ids))

    assert MapSet.new(accounts) == MapSet.new(rows, &%{username: &1.username, uid: &1.uid})
    assert length(accounts) == length(rows)

    usernames = Enum.map(accounts, & &1.username)
    uids = Enum.map(accounts, & &1.uid)
    assert usernames == Enum.uniq(usernames)
    assert uids == Enum.uniq(uids)

    by_pair = Map.new(rows, &{{&1.username, &1.uid}, &1.user_id})
    order = Enum.map(accounts, &Map.fetch!(by_pair, {&1.username, &1.uid}))
    assert order == Enum.sort(order)

    for %{username: username, uid: uid} <- accounts do
      assert uid in 200_000..999_999
      assert byte_size(username) <= 32
      assert username == "u#{uid}"
    end

    :ok
  end

  # Independent oracle: raw grant/membership reads, an independently filtered
  # User set and a fresh per-candidate Cedar write re-check. This never calls
  # the roster's own candidate derivation.
  @spec expected_writer_ids(Marshall.Compute.VirtualMachine.t()) :: [String.t()]
  defp expected_writer_ids(vm) do
    grant_ids =
      Marshall.Access.Grant
      |> Ash.Query.filter(vm_id == ^vm.id)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.user_id)

    member_ids =
      if vm.team_id do
        Marshall.Teams.TeamMember
        |> Ash.Query.filter(team_id == ^vm.team_id)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(& &1.user_id)
      else
        []
      end

    [vm.owner_id | grant_ids ++ member_ids]
    |> Enum.uniq()
    |> Enum.filter(fn id ->
      case Marshall.Accounts.Security.current(id) do
        %User{deleted_at: nil} = user ->
          Marshall.Access.Authorization.allowed?(vm, user, "write")

        _ ->
          false
      end
    end)
    |> Enum.sort()
  end

  @spec identity_rows([String.t()]) :: [
          {String.t(), String.t(), String.t(), integer(), DateTime.t() | nil}
        ]
  defp identity_rows(ids) do
    GuestAccount
    |> Ash.Query.filter(user_id in ^ids)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.map(&{&1.user_id, &1.id, &1.username, &1.uid, &1.retired_at})
    |> Enum.sort()
  end

  @spec vm_fixture(boolean()) :: {Marshall.Compute.VirtualMachine.t(), String.t(), map()}
  defp vm_fixture(team?) do
    # A property run creates several fixtures inside one sandbox transaction;
    # already-created hosts MUST be disabled so each new VM keeps its own
    # physical machine identity (the roster_fixtures!/2 capture pattern).
    for host <- Ledger.read!(Marshall.Compute.Host, enabled: true) do
      Ledger.update!(host, :configure, %{enabled: false})
    end

    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})

    if team? do
      {:ok, team} =
        Marshall.Teams.create_team(
          %{name: "roster-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: fixture.owner
        )

      {:ok, vm} =
        Marshall.Compute.provision(
          Marshall.ComputeFixtures.request(%{team_id: team.id, profile: :oss, vcpu: 1}),
          actor: fixture.owner
        )

      [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)

      {vm, roster_token(vm),
       %{
         "host_id" => vm.host_id,
         "vm_id" => vm.id,
         "placement_id" => vm.current_placement_id,
         "execution_epoch" => vm.execution_epoch,
         "operation_id" => operation.id,
         "generation" => vm.generation
       }}
    else
      {fixture.vm, roster_token(fixture.vm), Marshall.TerminalFixtures.roster_binding(fixture.vm)}
    end
  end

  @spec roster_token(Marshall.Compute.VirtualMachine.t()) :: String.t()
  defp roster_token(vm) do
    {:ok, credential} = Credentials.rotate(vm.host_id, 3600)
    credential.id <> "." <> credential.secret
  end

  @spec owner_of(Marshall.Compute.VirtualMachine.t()) :: User.t()
  defp owner_of(vm) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^vm.owner_id)
    |> Ash.read_one!()
  end

  @spec grant(Marshall.Compute.VirtualMachine.t(), User.t(), User.t(), atom()) ::
          {:ok, term()} | {:error, term()}
  defp grant(vm, owner, user, role) do
    Marshall.Access.set_access(
      %{
        vm_id: vm.id,
        email: to_string(user.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: owner
    )
  end

  @spec join!(String.t(), User.t(), atom(), User.t()) :: :ok
  defp join!(team_id, member, role, owner) do
    {:ok, _} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team_id,
          email: to_string(member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    :ok
  end

  @spec retire!(User.t(), User.t()) :: :ok
  defp retire!(user, admin) do
    {:ok, %{deleting: true}} =
      User
      |> Ash.ActionInput.for_action(
        :delete_user,
        %{user_id: user.id, confirmation: to_string(user.email)},
        actor: admin
      )
      |> Ash.run_action()

    :ok
  end

  @spec restart_sequence!(200_000..999_999) :: :ok
  defp restart_sequence!(first) when first in 200_000..999_999 do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "ALTER SEQUENCE account_guest_uid_seq RESTART WITH " <> Integer.to_string(first),
      [],
      log: false
    )

    :ok
  end
end
