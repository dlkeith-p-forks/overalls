defmodule Marshall.SSH.KeyTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures, only: [user: 0]
  alias Marshall.SSH

  @tag :hegel_case_sandbox
  property "canonical key ownership survives duplicate registration and changes only after revocation",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    owner = user()
    other = user()

    bytes = draw("bytes", binary(length: 32))
    label = draw("label", string(:alphanumeric, max_length: 32))
    public_key = encode(bytes)
    assert {:ok, key} = SSH.add_key(%{public_key: public_key, label: label}, actor: owner)
    assert {:ok, same} = SSH.add_key(%{public_key: public_key <> " comment"}, actor: owner)
    assert same.id == key.id
    assert {:error, _} = SSH.add_key(%{public_key: public_key}, actor: other)
    assert {:error, _} = SSH.remove_key(%{id: key.id}, actor: other)
    assert {:ok, [listed]} = SSH.list_keys(%{}, actor: owner)
    assert listed.id == key.id
    refute Map.has_key?(listed, :public_key)
    assert {:ok, []} = SSH.list_keys(%{}, actor: other)
    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: key.id}, actor: owner)
    assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
    assert {:ok, replacement} = SSH.add_key(%{public_key: public_key}, actor: owner)
    refute replacement.id == key.id
    assert {:ok, _} = SSH.remove_key(%{id: replacement.id}, actor: owner)
  end

  test "public actions require an account and raw resource access remains internal" do
    assert {:error, _} = SSH.add_key(%{public_key: encode(<<0::256>>)}, actor: nil)
    assert {:error, _} = SSH.list_keys(%{}, actor: nil)
    assert {:error, _} = Ash.read(SSH.Key, actor: user())
  end

  test "administrator inventory is bounded and revokes without exposing key material" do
    owner = user()

    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{
        email: "admin-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })
      |> Marshall.PasskeyFixture.verified_session()

    {:ok, key} = SSH.add_key(%{public_key: encode(<<9::256>>), label: "admin-view"}, actor: owner)

    assert {:ok, [listed]} = SSH.list_keys_for_admin(%{}, actor: admin)
    assert listed.id == key.id
    assert listed.email == owner.email
    assert listed.fingerprint
    refute Map.has_key?(listed, :public_key)
    refute Map.has_key?(listed, :token_hash)

    assert {:ok, %{revoked: true}} = SSH.revoke_key_for_admin(%{id: key.id}, actor: admin)
    assert {:ok, []} = SSH.list_keys_for_admin(%{}, actor: admin)

    assert [%{kind: :ssh_key_revoke, target_id: id}] =
             Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent, target_id: key.id)

    assert id == key.id
  end

  test "invalid keys never create records and client ownership cannot select the account" do
    owner = user()
    other = user()

    assert {:error, _} =
             SSH.add_key(%{public_key: "-----BEGIN OPENSSH PRIVATE KEY-----"}, actor: owner)

    assert {:ok, []} = SSH.list_keys(%{}, actor: owner)

    assert {:error, _} =
             SSH.add_key(%{public_key: encode(<<1::256>>), user_id: other.id}, actor: owner)

    assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
    assert {:ok, []} = SSH.list_keys(%{}, actor: other)
  end

  test "key lifecycle emits structured events without key material" do
    owner = user()
    label_marker = "label-secret-#{System.unique_integer([:positive])}"
    public = encode(:crypto.strong_rand_bytes(32))
    parent = self()

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :key_id, :user_id]],
        fn ->
          {:ok, key} = SSH.add_key(%{public_key: public, label: label_marker}, actor: owner)
          assert {:ok, _same} = SSH.add_key(%{public_key: public}, actor: owner)
          assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: key.id}, actor: owner)
          send(parent, {:key, key.id})
        end
      )

    assert_receive {:key, id}
    assert logs =~ "Account SSH key added"
    assert logs =~ "Account SSH key removed"
    assert logs =~ "key_id=" <> id
    assert logs =~ "user_id=" <> owner.id
    assert length(Regex.scan(~r/Account SSH key added/, logs)) == 1
    refute logs =~ label_marker
    refute logs =~ public
  end

  test "key versions audit lifecycle without retaining public key or label values" do
    owner = user()
    label_marker = "versioned-label-#{System.unique_integer([:positive])}"
    public = encode(<<11::256>>)

    {:ok, key} = SSH.add_key(%{public_key: public, label: label_marker}, actor: owner)
    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: key.id}, actor: owner)

    versions = Marshall.Compute.Ledger.read!(SSH.Key.Version, version_source_id: key.id)
    refute versions == []

    for version <- versions do
      refute Map.has_key?(version.changes, "public_key")
      refute Map.has_key?(version.changes, :public_key)
      refute Map.has_key?(version.changes, "label")
      refute Map.has_key?(version.changes, :label)
      refute inspect(version) =~ label_marker
      refute inspect(version) =~ public
    end
  end

  test "one hundred owned keys bound registration; removal re-admits it" do
    owner = user()

    for i <- 1..100 do
      assert {:ok, _} =
               SSH.add_key(
                 %{public_key: encode(:crypto.strong_rand_bytes(32)), label: "key-#{i}"},
                 actor: owner
               )
    end

    assert {:ok, keys} = SSH.list_keys(%{}, actor: owner)
    assert length(keys) == 100

    assert {:error, %Ash.Error.Invalid{errors: [%Marshall.SSH.Error{reason: :key_limit}]}} =
             SSH.add_key(%{public_key: encode(:crypto.strong_rand_bytes(32))}, actor: owner)

    assert {:ok, listed} = SSH.list_keys(%{}, actor: owner)
    assert length(listed) == 100

    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: hd(listed).id}, actor: owner)
    assert {:ok, listed} = SSH.list_keys(%{}, actor: owner)
    assert length(listed) == 99

    assert {:ok, _} =
             SSH.add_key(%{public_key: encode(:crypto.strong_rand_bytes(32))}, actor: owner)

    assert {:ok, listed} = SSH.list_keys(%{}, actor: owner)
    assert length(listed) == 100
  end

  defp encode(bytes),
    do: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
end
