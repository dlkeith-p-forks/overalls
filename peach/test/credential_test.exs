defmodule Peach.CredentialTest do
  use ExUnit.Case, async: true

  test "runtime credentials must be private, bounded, regular files" do
    dir = Path.join(System.tmp_dir!(), "peach-key-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "key")
    File.write!(path, "synthetic-key\n")
    File.chmod!(path, 0o600)
    assert {:ok, "synthetic-key"} = Peach.Credential.read(path)
    File.chmod!(path, 0o640)
    assert {:error, :invalid_credential} = Peach.Credential.read(path)
    File.chmod!(path, 0o600)
    File.write!(path, "synthetic\ninjection")
    assert {:error, :invalid_credential} = Peach.Credential.read(path)
    File.ln_s!(path, path <> "-link")
    assert {:error, :invalid_credential} = Peach.Credential.read(path <> "-link")
    assert {:error, :invalid_credential} = Peach.Credential.read("/nix/store/synthetic/key")
    assert {:error, :invalid_credential} = Peach.Credential.read(nil)
  end
end
