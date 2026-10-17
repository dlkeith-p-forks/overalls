defmodule Marshall.CommittedCredentialInventoryTest do
  @moduledoc """
  Committed credential-management lifecycles: an unrelated committed fixture
  with its own passkey, SSH key and audit rows must be preserved exactly, and
  complete row-hash teardown of the lifecycle's own rows MUST restore the
  complete prior public-table inventory (029 pattern).
  """
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.PasskeyFixture
  alias Marshall.Accounts.{Security, User}
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.CommittedFixtureInventory
  alias Marshall.Repo
  alias Marshall.SSH

  # @cc [owner:ghuntley,label:verification] credential-committed-inventory-history
  # Committed credential lifecycles MUST end with the complete public-table row
  # inventory restored, including unrelated committed fixtures. Lifecycle proof
  # MUST invoke the real ceremony/key actions and assert session revocation
  # effects against raw committed state before exact teardown.
  @tag timeout: 120_000
  property "committed credential lifecycles preserve unrelated fixture history and restore inventory" do
    check all(bytes <- binary(length: 32), max_runs: 8) do
      unboxed(fn -> verify_lifecycle!(bytes) end)
    end
  end

  @spec verify_lifecycle!(binary()) :: :ok
  defp verify_lifecycle!(bytes) do
    original = CommittedFixtureInventory.snapshot()
    {control, control_device, control_ssh} = control_fixture!(bytes)

    Cleanup.run(
      fn ->
        assert passkey_rows(control.id) |> Enum.any?(&(&1.credential_id == control_device.id))
        refute archived_ssh?(control_ssh)

        protected = CommittedFixtureInventory.snapshot()
        subject = user()

        Cleanup.run(
          fn ->
            run_subject_history!(subject.id, bytes)
            refute CommittedFixtureInventory.snapshot() == protected
            :ok
          end,
          fn ->
            cleanup_user!(subject.id)
            CommittedFixtureInventory.assert_restored!(protected)
          end
        )

        CommittedFixtureInventory.assert_restored!(protected)
        :ok
      end,
      fn -> cleanup_user!(control.id) end
    )

    CommittedFixtureInventory.assert_restored!(original)
    :ok
  end

  @spec control_fixture!(binary()) :: {User.t(), map(), String.t()}
  defp control_fixture!(bytes) do
    control = user()
    {actor, _token} = login(control)
    device = register(actor)
    assert {:ok, %{verified: true}} = verify(actor, device)

    {:ok, ssh} =
      SSH.add_key(%{public_key: ssh_public_key(bytes), label: "control"}, actor: actor)

    refute Repo.in_transaction?()
    {control, device, ssh.id}
  end

  # ---------------------------------------------------------------- helpers

  @spec run_subject_history!(String.t(), binary()) :: :ok
  defp run_subject_history!(subject_id, bytes) do
    {actor, _token} = login(Security.current(subject_id))

    first = register(actor)
    assert {:ok, %{verified: true}} = verify(actor, first)
    second = register(actor)

    [first_row, second_row] = rows_for(actor.id, [first, second])

    assert {:ok, %{updated: true}} =
             action(actor, :rename, %{"id" => first_row.id, "label" => "work"})

    {:ok, ssh_a} =
      SSH.add_key(%{public_key: ssh_public_key(:crypto.hash(:sha256, "a" <> bytes)), label: "a"},
        actor: actor
      )

    {:ok, ssh_b} =
      SSH.add_key(%{public_key: ssh_public_key(:crypto.hash(:sha256, "b" <> bytes)), label: "b"},
        actor: actor
      )

    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: ssh_a.id}, actor: actor)
    assert archived_ssh?(ssh_a.id)
    refute archived_ssh?(ssh_b.id)

    # Removing the non-proving credential preserves elevation.
    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => second_row.id})
    assert Security.recent?(actor)

    {other, _other_token} = login(Security.current(subject_id))
    assert {:ok, %{verified: true}} = verify(other, first)

    # Ordinary last-passkey removal revokes both stored sessions.
    assert live_logins(subject_id) == 2
    assert {:ok, %{updated: true}} = action(actor, :remove, %{"id" => first_row.id})
    assert live_logins(subject_id) == 0
    assert %{mfa_enabled: false} = Security.current(subject_id)
    assert {:error, _} = action(other, :status)

    # Fresh email recovery admits a replacement credential, which is removable
    # again after verification.
    {restored, _restored_token} = login(Security.current(subject_id))
    third = register(restored)
    assert %{mfa_enabled: true} = Security.current(subject_id)
    assert {:ok, %{verified: true}} = verify(restored, third)
    [third_row] = passkey_rows(subject_id)
    assert {:ok, %{updated: true}} = action(restored, :remove, %{"id" => third_row.id})
    assert live_logins(subject_id) == 0
    assert %{mfa_enabled: false} = Security.current(subject_id)

    :ok
  end

  @spec cleanup_user!(String.t()) :: :ok
  defp cleanup_user!(user_id) do
    dumped = Ecto.UUID.dump!(user_id)

    for table <- ~w(account_passkey_challenges account_verifications account_passkeys) do
      query!("DELETE FROM " <> table <> " WHERE user_id=$1", [dumped])
    end

    query!("DELETE FROM tokens WHERE subject=$1", ["user?id=" <> user_id])

    query!(
      "DELETE FROM ssh_keys_versions WHERE version_source_id IN (SELECT id FROM ssh_keys WHERE user_id=$1)",
      [dumped]
    )

    query!("DELETE FROM ssh_keys WHERE user_id=$1", [dumped])
    query!("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [dumped])
    query!("DELETE FROM users WHERE id=$1", [dumped])
    :ok
  end

  @spec passkey_rows(String.t()) :: [map()]
  defp passkey_rows(user_id) do
    %{rows: rows} =
      query!(
        "SELECT id::text, label, credential_id FROM account_passkeys WHERE user_id=$1 ORDER BY inserted_at, id",
        [Ecto.UUID.dump!(user_id)]
      )

    Enum.map(rows, fn [id, label, credential_id] ->
      %{id: id, label: label, credential_id: credential_id}
    end)
  end

  @spec rows_for(String.t(), [map()]) :: [map()]
  defp rows_for(user_id, devices) do
    rows = passkey_rows(user_id)

    Enum.map(devices, fn device ->
      Enum.find(rows, &(&1.credential_id == device.id)) ||
        raise("registered passkey row not found for device")
    end)
  end

  @spec archived_ssh?(String.t()) :: boolean()
  defp archived_ssh?(id) do
    %{rows: [[present]]} =
      query!(
        "SELECT archived_at IS NOT NULL FROM ssh_keys WHERE id=$1",
        [Ecto.UUID.dump!(id)]
      )

    present
  end

  @spec live_logins(String.t()) :: non_neg_integer()
  defp live_logins(user_id) do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM tokens WHERE subject=$1 AND purpose='user' AND (expires_at AT TIME ZONE 'utc') > clock_timestamp()",
        ["user?id=" <> user_id]
      )

    count
  end

  @spec query!(String.t(), [term()]) :: Postgrex.Result.t()
  defp query!(sql, params), do: Repo.query!(sql, params, log: false)

  @spec ssh_public_key(binary()) :: String.t()
  defp ssh_public_key(bytes) do
    "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
  end

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(body), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, body)
end
