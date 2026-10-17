defmodule Marshall.VaultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  test "an ordered keyring encrypts with the first key and decrypts retained keys" do
    old = entry("old")
    new = entry("new")
    [{_, {module, old_opts}}] = Marshall.Vault.keyring!(JSON.encode!([old]))
    {:ok, ciphertext} = module.encrypt("probe", old_opts)

    [{_, {^module, new_opts}}, {_, {^module, retained_opts}}] =
      Marshall.Vault.keyring!(JSON.encode!([new, old]))

    refute module.can_decrypt?(ciphertext, new_opts)
    assert module.can_decrypt?(ciphertext, retained_opts)
    assert {:ok, "probe"} = module.decrypt(ciphertext, retained_opts)
    {:ok, fresh} = module.encrypt("probe", new_opts)
    assert module.can_decrypt?(fresh, new_opts)
  end

  test "invalid or duplicate keys fail without echoing input" do
    key = entry("same")

    for input <- [
          "secret-input",
          "null",
          "[]",
          JSON.encode!([key, key]),
          JSON.encode!([%{key | "key" => "bad-secret"}]),
          JSON.encode!([%{key | "id" => "bad id"}])
        ] do
      assert_raise ArgumentError, "invalid MARSHALL_CLOAK_KEYS keyring", fn ->
        Marshall.Vault.keyring!(input)
      end
    end

    assert_raise RuntimeError, "MARSHALL_CLOAK_KEYS is required", fn ->
      # Startup is fail-closed independently of the dev/test application config.
      Marshall.Vault.init(allow_development_key: false)
    end
  end

  property "arbitrary invalid JSON fails with a fixed, non-sensitive message" do
    check all(input <- binary(max_length: 128)) do
      try do
        Marshall.Vault.keyring!(input)
      rescue
        error in ArgumentError ->
          assert Exception.message(error) == "invalid MARSHALL_CLOAK_KEYS keyring"
      end
    end
  end

  defp entry(id), do: %{"id" => id, "key" => Base.encode64(:crypto.strong_rand_bytes(32))}
end
