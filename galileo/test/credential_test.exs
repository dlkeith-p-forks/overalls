defmodule Galileo.CredentialTest do
  use ExUnit.Case, async: true

  test "runtime keys must be private, bounded, regular files" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "galileo-key-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "key")
    File.write!(path, "synthetic-key\n")
    File.chmod!(path, 0o600)
    assert {:ok, "synthetic-key"} = Galileo.Credential.read(path)
    File.chmod!(path, 0o644)
    assert {:error, :invalid_credential} = Galileo.Credential.read(path)
    File.chmod!(path, 0o600)
    File.write!(path, "synthetic\ninjection")
    assert {:error, :invalid_credential} = Galileo.Credential.read(path)
    File.ln_s!(path, path <> "-link")
    assert {:error, :invalid_credential} = Galileo.Credential.read(path <> "-link")
    assert {:error, :invalid_credential} = Galileo.Credential.read("/nix/store/synthetic/key")
  end
end
