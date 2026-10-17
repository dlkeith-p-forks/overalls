defmodule Marshall.Accounts.ControlRoomAuthorityTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.User
  alias Marshall.Compute.Ledger

  test "recently elevated ordinary users may read projections but cannot use administrative domain actions" do
    reader = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.verified_session()
    other = Marshall.PasskeyFixture.user()
    host = Marshall.ComputeFixtures.host_fixture().host
    actor = %{reader | administrator: true}

    for {action, args} <- [
          {:set_administrator, %{user_id: other.id, administrator: true}},
          {:revoke_sessions_for_admin, %{user_id: other.id}},
          {:invite_user, %{email: "forbidden-invite@example.test"}},
          {:delete_user, %{user_id: other.id, confirmation: to_string(other.email)}},
          {:reset_mfa, %{user_id: other.id}}
        ] do
      assert {:error, _} =
               User |> Ash.ActionInput.for_action(action, args, actor: actor) |> Ash.run_action()
    end

    assert {:ok, %{items: items}} =
             User
             |> Ash.ActionInput.for_action(:list_admin_users, %{}, actor: reader)
             |> Ash.run_action()

    assert Enum.any?(items, &(&1.id == other.id))
    assert {:ok, _} = Marshall.SSH.list_keys_for_admin(%{}, actor: reader)
    assert {:ok, _} = Marshall.SSH.list_sessions_for_admin(%{}, actor: reader)
    assert {:ok, _} = Marshall.Access.list_grants_for_admin(%{}, actor: reader)
    assert {:ok, _} = Marshall.Compute.list_vms_for_admin(%{}, actor: reader)

    assert {:error, _} = Marshall.SSH.revoke_key_for_admin(%{id: other.id}, actor: actor)
    assert {:error, _} = Marshall.SSH.revoke_session_for_admin(%{id: other.id}, actor: actor)
    assert {:error, _} = Marshall.Access.revoke_grant_for_admin(%{id: other.id}, actor: actor)

    assert {:error, _} =
             Marshall.Administration.retry_job(%{id: 1, request_id: Ash.UUID.generate()},
               actor: actor
             )

    assert {:error, _} =
             Marshall.Compute.admin_configure_host(
               %{host_id: host.id, enabled: false, overhead_cores: 0, overhead_memory_bytes: 0},
               actor: actor
             )

    assert {:error, _} = Marshall.Ingress.rotate_fleet_certificate(%{}, actor: actor)
    assert {:error, _} = Marshall.Enrico.Catalog.register(actor, "NixOS", "nixpkgs")
    assert {:error, _} = Marshall.Enrico.Catalog.refresh(actor, other.id)
    assert {:error, _} = Marshall.Enrico.Catalog.remove(actor, other.id)

    assert Ledger.read!(Marshall.Accounts.AdminEvent) == []
    assert Ledger.read!(Marshall.Enrico.Repository) == []
    refute Marshall.Accounts.Security.current(other.id).administrator
  end
end
