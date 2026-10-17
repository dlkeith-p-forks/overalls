defmodule Marshall.Compute.AdminHostConfigurationTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute
  alias Marshall.Compute.Ledger

  test "current administrators change margins under the host lock and the action is audited" do
    %{host: host} = host_fixture()

    admin =
      Ledger.update!(user(), :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    assert {:ok, result} =
             Compute.admin_configure_host(
               %{
                 host_id: host.id,
                 enabled: true,
                 overhead_cores: 3,
                 overhead_memory_bytes: 2_147_483_648
               },
               actor: admin
             )

    assert result.enabled

    assert [%{overhead_cores: 3, overhead_memory_bytes: 2_147_483_648}] =
             Ledger.read!(Marshall.Compute.Host, id: host.id)

    host_id = host.id

    assert [%{kind: :host_configure, actor_id: actor_id, target_id: ^host_id}] =
             Ledger.read!(AdminEvent, target_id: host.id)

    assert actor_id == admin.id
  end

  test "enabling a stale host and forged administrator authority are rejected" do
    %{host: host} = host_fixture()

    admin =
      Ledger.update!(user(), :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    Ledger.update!(host, :disconnect, %{reported_at: nil})

    assert {:error, _} =
             Compute.admin_configure_host(
               %{host_id: host.id, enabled: true, overhead_cores: 1, overhead_memory_bytes: 1},
               actor: admin
             )

    ordinary = Ledger.update!(user(), :assign_administrator, %{administrator: false})

    assert {:error, _} =
             Compute.admin_configure_host(
               %{host_id: host.id, enabled: false, overhead_cores: 1, overhead_memory_bytes: 1},
               actor: %{ordinary | administrator: true}
             )
  end
end
