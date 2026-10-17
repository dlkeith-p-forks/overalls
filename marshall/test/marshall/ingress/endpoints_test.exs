defmodule Marshall.Ingress.EndpointsTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  import Marshall.ComputeFixtures
  alias Marshall.{Compute, Ingress}
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.Endpoint

  setup do
    host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(%{name: "audi-test"}), actor: owner)
    %{owner: owner, vm: vm, other: user()}
  end

  test "provisioning creates a private stable endpoint in the same transaction", ctx do
    assert [endpoint] = Ledger.read!(Endpoint, vm_id: ctx.vm.id)
    assert Ledger.read!(Marshall.Ingress.Environment, vm_id: ctx.vm.id) == []
    assert endpoint.visibility == :private
    assert endpoint.primary_port == 80
    assert endpoint.policy_revision == 1
    assert endpoint.label == OverallsProtocol.IngressName.label(ctx.vm.name, ctx.vm.id)
    assert [_] = Ledger.read!(Endpoint.Version, version_source_id: endpoint.id)
    assert {:error, _} = Ingress.get_endpoint(%{vm_id: ctx.vm.id}, actor: ctx.other)
  end

  test "visibility changes are audited and stale revisions cannot overwrite them", ctx do
    assert {:ok, original} = Ingress.get_endpoint(%{vm_id: ctx.vm.id}, actor: ctx.owner)
    params = %{vm_id: ctx.vm.id, expected_revision: 1, primary_port: 4000, visibility: :public}
    assert {:ok, changed} = Ingress.configure_endpoint(params, actor: ctx.owner)
    assert changed.policy_revision == 2
    assert changed.label == original.label
    assert changed.visibility == :public

    assert {:error, _} =
             Ingress.configure_endpoint(%{params | visibility: :private}, actor: ctx.owner)

    assert {:ok, ^changed} =
             Ingress.configure_endpoint(%{params | expected_revision: 2}, actor: ctx.owner)

    assert length(Ledger.read!(Endpoint.Version, version_source_id: changed.id)) == 2
  end

  test "configuration checks current membership and denies raw user mutations", ctx do
    params = %{vm_id: ctx.vm.id, expected_revision: 1, primary_port: 4000, visibility: :private}

    share = %{
      vm_id: ctx.vm.id,
      email: to_string(ctx.other.email),
      role: :viewer,
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, _} = Marshall.Access.set_access(share, actor: ctx.owner)
    assert {:ok, _} = Ingress.get_endpoint(%{vm_id: ctx.vm.id}, actor: ctx.other)
    assert {:error, _} = Ingress.configure_endpoint(params, actor: ctx.other)

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{share | role: :manager, idempotency_key: Ash.UUID.generate()},
               actor: ctx.owner
             )

    assert {:ok, changed} = Ingress.configure_endpoint(params, actor: ctx.other)

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{share | role: :revoked, idempotency_key: Ash.UUID.generate()},
               actor: ctx.owner
             )

    assert {:error, _} =
             Ingress.configure_endpoint(
               %{params | expected_revision: changed.policy_revision, primary_port: 5000},
               actor: ctx.other
             )

    [endpoint] = Ledger.read!(Endpoint, vm_id: ctx.vm.id)

    assert {:error, _} =
             endpoint
             |> Ash.Changeset.for_update(
               :change_policy,
               %{visibility: :public, policy_revision: 99},
               actor: ctx.owner
             )
             |> Ash.update()

    assert [current] = Ledger.read!(Endpoint, vm_id: ctx.vm.id)
    assert current.visibility == :private
    assert current.policy_revision == 2
  end

  property "generated policy changes preserve identity and count only actual mutations", ctx do
    check all(
            changes <-
              list_of(tuple({integer(1..65535), member_of([:private, :public])}),
                min_length: 1,
                max_length: 20
              ),
            max_runs: 20
          ) do
      {:ok, initial} = Ingress.get_endpoint(%{vm_id: ctx.vm.id}, actor: ctx.owner)

      Enum.reduce(changes, initial, fn {port, visibility}, before ->
        params = %{
          vm_id: ctx.vm.id,
          expected_revision: before.policy_revision,
          primary_port: port,
          visibility: visibility
        }

        if port == 4444 do
          assert {:error, _} = Ingress.configure_endpoint(params, actor: ctx.owner)
          assert {:ok, current} = Ingress.get_endpoint(%{vm_id: ctx.vm.id}, actor: ctx.owner)
          assert current == before
          before
        else
          assert {:ok, after_change} = Ingress.configure_endpoint(params, actor: ctx.owner)

          delta =
            if port == before.primary_port and visibility == before.visibility, do: 0, else: 1

          assert after_change.policy_revision == before.policy_revision + delta
          assert after_change.label == initial.label
          assert after_change.vm_id == ctx.vm.id
          assert after_change.primary_port == port
          assert after_change.visibility == visibility
          after_change
        end
      end)
    end
  end
end
