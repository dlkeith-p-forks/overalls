defmodule Marshall.Compute.ViewsBatchedReadsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Access.Authorization
  alias Marshall.Authorization.DecisionSnapshot
  alias Marshall.Compute

  @machines 4

  setup do
    # Each fixture host admits only a few small machines.
    fixture = host_fixture()
    host_fixture()
    owner = user()
    member = user()

    vms =
      for _ <- 1..@machines do
        {:ok, vm} =
          Compute.provision(request(%{vcpu: 1}), actor: owner)

        vm
      end

    Map.merge(fixture, %{owner: owner, member: member, vms: vms})
  end

  # @cc [owner:ghuntley,label:verification;security] views-batched-decision-equivalence
  # For any combination of current machine grants, the batched page MUST list
  # exactly the machines a fresh per-row read decision allows and MUST project
  # the same read/write/manage permissions those fresh decisions return.
  @tag :hegel
  @tag timeout: 300_000
  test "batched pages make the same decisions as fresh per-row checks", context do
    Hegel.check(
      fn ->
        roles =
          draw(
            "roles",
            list_of(member_of([:viewer, :operator, :manager, :revoked]),
              min_length: @machines,
              max_length: @machines
            )
          )

        for {vm, role} <- Enum.zip(context.vms, roles), do: share(context, vm, role)

        assert {:ok, %{items: items}} = Compute.list_vms(%{limit: 50}, actor: context.member)
        listed = Map.new(items, &{&1.id, &1.permissions})

        for vm <- context.vms do
          fresh = fresh_permissions(vm, context.member)

          if fresh.read,
            do: assert(listed[vm.id] == fresh),
            else: refute(Map.has_key?(listed, vm.id))
        end
      end,
      test_cases: 10
    )
  end

  # @cc [owner:ghuntley,label:verification;security] views-batch-no-cross-request-reuse
  # A revocation committed between two reads MUST hide the machine on the next
  # read; memoized reads MUST NOT outlive their batch.
  test "a revoked grant disappears on the next page read", context do
    [vm | _] = context.vms
    share(context, vm, :manager)
    assert {:ok, %{items: [%{id: id}]}} = Compute.list_vms(%{limit: 50}, actor: context.member)
    assert id == vm.id
    refute DecisionSnapshot.active?()

    share(context, vm, :revoked)
    assert {:ok, %{items: []}} = Compute.list_vms(%{limit: 50}, actor: context.member)
  end

  test "memoized reads are confined to their batch" do
    calls = :counters.new(1, [])
    read = fn -> :counters.add(calls, 1, 1) end

    DecisionSnapshot.fetch(:key, read)
    DecisionSnapshot.fetch(:key, read)
    assert :counters.get(calls, 1) == 2

    assert {:ok, :done} =
             DecisionSnapshot.transaction(fn ->
               DecisionSnapshot.fetch(:key, read)
               DecisionSnapshot.fetch(:key, read)
               :done
             end)

    assert :counters.get(calls, 1) == 3
    refute DecisionSnapshot.active?()
    DecisionSnapshot.fetch(:key, read)
    assert :counters.get(calls, 1) == 4
  end

  # @cc [owner:ghuntley,label:verification;observability] views-query-budget
  # A machine page without relocations MUST read the same number of queries
  # regardless of how many machines it projects.
  test "page queries do not grow with additional machines", context do
    small = queries(fn -> Compute.list_vms(%{limit: 50}, actor: context.owner) end)

    for _ <- 1..4, do: host_fixture()

    for _ <- 1..8 do
      {:ok, _} =
        Compute.provision(request(%{vcpu: 1}), actor: context.owner)
    end

    large = queries(fn -> Compute.list_vms(%{limit: 50}, actor: context.owner) end)
    assert large == small, "#{small} queries for #{@machines}, #{large} for #{@machines + 8}"
  end

  # @cc [owner:ghuntley,label:verification;observability] views-batched-relocation-status
  # A batched page MUST project the same relocation status as a fresh per-row
  # read. Relocated machines keep the per-row read; the settings LiveView test
  # covers one through the batched path.
  test "listed relocation status matches the per-row read", context do
    {:ok, page} = Compute.list_vms(%{limit: 50}, actor: context.owner)
    assert length(page.items) == @machines

    for item <- page.items do
      assert item.permissions.manage
      assert item.relocation == Marshall.Compute.RelocationStatus.latest(item.id)
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] catalog-query-budget
  # The creation catalog MUST read hosts, reservations, pools and images in a
  # number of queries independent of the number of eligible hosts.
  test "catalog queries do not grow with eligible hosts", context do
    small = queries(fn -> Compute.catalog(%{}, actor: context.owner) end)
    for _ <- 1..4, do: host_fixture()

    {{:ok, catalog}, large} =
      Marshall.Observability.count_queries(fn ->
        Compute.catalog(%{}, actor: context.owner)
      end)

    assert catalog.capacity_known
    assert large == small, "#{small} queries for 2 hosts, #{large} for 6"
  end

  @spec queries((-> {:ok, map()})) :: non_neg_integer()
  defp queries(fun) do
    {{:ok, _}, count} = Marshall.Observability.count_queries(fun)
    count
  end

  @spec fresh_permissions(Compute.VirtualMachine.t(), Marshall.Accounts.User.t()) :: map()
  defp fresh_permissions(vm, actor) do
    refute DecisionSnapshot.active?()
    Map.new([:read, :write, :manage], &{&1, Authorization.allowed?(vm, actor, to_string(&1))})
  end

  @spec share(map(), Compute.VirtualMachine.t(), atom()) :: term()
  defp share(context, vm, role) do
    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(context.member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: context.owner
      )
  end
end
