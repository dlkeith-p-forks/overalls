defmodule Lilly.Control.CredentialFileTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.CredentialFile
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"

  @tag :hegel

  test "arbitrary file contents fail without disclosing payloads", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "credential.json")

    check all(bytes <- binary(max_length: 1024)) do
      File.write!(path, bytes)
      File.chmod!(path, 0o600)
      assert {:error, :invalid_credential_file} = CredentialFile.read(path, @id)
    end
  end

  test "envelopes reject mismatched IDs, unknown fields and malformed metadata", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "credential.json")

    envelope = %{
      "version" => 1,
      "host_id" => @id,
      "credential_id" => @id,
      "credential" => @id <> ":" <> String.duplicate("a", 43),
      "expires_at" => "2030-01-01T00:00:00Z"
    }

    for value <- [
          Map.put(envelope, "version", 2),
          Map.put(envelope, "extra", true),
          Map.put(envelope, "credential_id", "22222222-2222-4222-8222-222222222222"),
          Map.put(envelope, "expires_at", nil),
          Map.put(envelope, "credential", String.duplicate("x", 80))
        ] do
      File.write!(path, JSON.encode!(value))
      File.chmod!(path, 0o600)
      assert {:error, :invalid_credential_file} = CredentialFile.read(path, @id)
    end
  end
end
