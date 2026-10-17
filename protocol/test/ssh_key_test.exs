defmodule OverallsProtocol.SSHKeyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.SSHKey

  property "public key identity ignores comments and whitespace but binds every key byte" do
    check all(bytes <- binary(length: 32), comment <- string(:alphanumeric, max_length: 80)) do
      blob = <<11::32, "ssh-ed25519", 32::32, bytes::binary>>
      text = "ssh-ed25519 " <> Base.encode64(blob)
      assert {:ok, key} = SSHKey.parse(text)
      assert {:ok, ^key} = SSHKey.parse("  " <> text <> "\t" <> comment <> "\n")
      assert key.public_key == text

      assert key.fingerprint ==
               "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)

      assert {:ok, ^key} = SSHKey.from_blob(blob)
    end
  end

  property "arbitrary terms and bytes return bounded fixed errors" do
    check all(value <- one_of([term(), binary(max_length: 5000)])) do
      for result <- [SSHKey.parse(value), SSHKey.from_blob(value)] do
        assert match?({:ok, %{public_key: _, fingerprint: _, algorithm: _}}, result) or
                 result == {:error, :invalid_public_key}
      end
    end
  end

  test "options, multiple keys, private keys, inconsistent tags and trailing wire bytes fail" do
    blob = <<11::32, "ssh-ed25519", 32::32, 0::256>>
    key = "ssh-ed25519 " <> Base.encode64(blob)

    for invalid <- [
          "command=\"sh\" " <> key,
          key <> "\n" <> key,
          "-----BEGIN OPENSSH PRIVATE KEY-----",
          "ssh-rsa " <> Base.encode64(blob),
          "ssh-ed25519 " <> Base.encode64(blob <> <<0>>),
          String.duplicate("x", 4097)
        ] do
      assert SSHKey.parse(invalid) == {:error, :invalid_public_key}
    end
  end

  test "RSA requires canonical positive integers and at least 2048 bits" do
    encode = fn n ->
      modulus = <<0, n::2048>>
      blob = <<7::32, "ssh-rsa", 3::32, 1, 0, 1, byte_size(modulus)::32, modulus::binary>>
      "ssh-rsa " <> Base.encode64(blob)
    end

    assert {:ok, %{algorithm: "ssh-rsa"}} = SSHKey.parse(encode.(Bitwise.bsl(1, 2047) + 1))
    assert {:error, :invalid_public_key} = SSHKey.parse(encode.(17))
  end
end
