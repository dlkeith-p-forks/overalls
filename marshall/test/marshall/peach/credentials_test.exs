defmodule Marshall.Peach.CredentialsTest do
  use Marshall.DataCase, async: false

  import Marshall.ComputeFixtures

  alias Marshall.Compute.Ledger
  alias Marshall.Peach.{Credential, Credentials, IssuedCredential}

  test "rotation authenticates the new secret, revokes the old one and retains secret-free audit" do
    %{host: host} = host_fixture()

    assert {:ok, first} = Credentials.rotate(host.id, 3_600)

    assert {:ok, %{host_id: host_id, credential_id: first_id}} =
             Credentials.authenticate(token(first))

    assert host_id == host.id
    assert first_id == first.id

    assert {:ok, second} = Credentials.rotate(host.id, 3_600)
    assert {:error, :unauthorized} = Credentials.authenticate(token(first))
    assert {:ok, %{credential_id: second_id}} = Credentials.authenticate(token(second))
    assert second_id == second.id

    versions = Ledger.read!(Credential.Version, version_source_id: first.id)
    assert Enum.sort(Enum.map(versions, & &1.version_action_name)) == [:issue, :revoke]
    assert Enum.all?(versions, &(&1.actor_kind == :operator))
    refute Enum.any?(versions, &Map.has_key?(&1.changes, "secret_hash"))
    refute inspect(versions) =~ first.secret

    assert {:ok, :ok} = Credentials.revoke(host.id)
    assert {:error, :unauthorized} = Credentials.authenticate(token(second))
  end

  test "users cannot read or mutate internal credentials or their audit history" do
    %{host: host} = host_fixture()
    actor = user()

    assert {:ok, issued} = Credentials.rotate(host.id, 3_600)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Credential, actor: actor)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Credential.Version, actor: actor)

    [credential] = Ledger.read!(Credential, id: issued.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(credential, %{revoked_at: DateTime.utc_now()},
               action: :revoke,
               actor: actor
             )

    assert {:ok, %{credential_id: credential_id}} = Credentials.authenticate(token(issued))
    assert credential_id == issued.id
  end

  @spec token(IssuedCredential.t()) :: String.t()
  defp token(%IssuedCredential{id: id, secret: secret}), do: id <> "." <> secret
end
