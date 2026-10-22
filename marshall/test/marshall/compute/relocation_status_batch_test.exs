defmodule Marshall.Compute.RelocationStatusBatchTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Ledger, Operation, RelocationStatus}

  # @cc [owner:ghuntley,label:verification;observability] relocation-status-batch-equivalence
  # The batched relocation status MUST equal the per-row status for relocated,
  # cancelled and never-relocated machines, both directly and on a listed page.
  test "batched relocation status equals the per-row read" do
    host_fixture()
    owner = user()
    {:ok, relocated} = Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: relocated.id)
    Ledger.update!(operation, :complete, %{})
    Ledger.update!(relocated, :observe, %{observed_state: :running})
    host_fixture()

    {:ok, _} =
      Compute.relocate(%{vm_id: relocated.id, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    {:ok, plain} = Compute.provision(request(%{vcpu: 1}), actor: owner)
    ids = [relocated.id, plain.id, Ash.UUID.generate()]

    assert_equivalent(ids)
    assert %{active: true} = RelocationStatus.latest(relocated.id)
    assert RelocationStatus.latest(plain.id) == nil

    %{id: relocation_id} = RelocationStatus.latest(relocated.id)
    {:ok, _} = Compute.cancel_relocation(%{relocation_id: relocation_id}, actor: owner)

    assert_equivalent(ids)

    {:ok, page} = Compute.list_vms(%{limit: 50}, actor: owner)
    assert length(page.items) == 2

    for item <- page.items do
      assert item.relocation == RelocationStatus.latest(item.id)
    end

    assert Enum.count(page.items, &(&1.relocation != nil)) == 1
  end

  @spec assert_equivalent([String.t()]) :: :ok
  defp assert_equivalent(ids) do
    assert RelocationStatus.latest_many(ids) == Map.new(ids, &{&1, RelocationStatus.latest(&1)})
    :ok
  end
end
