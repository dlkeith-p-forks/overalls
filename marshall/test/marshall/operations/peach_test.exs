defmodule Marshall.Operations.PeachTest do
  use Marshall.DataCase, async: false

  import Marshall.ComputeFixtures

  alias Marshall.Operations.CLI
  @moduletag :tmp_dir

  test "rotate writes a private token, verify authenticates it and revoke retires it", %{
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)
    %{host: host} = host_fixture()
    output = Path.join(dir, "peach.token")

    assert {:ok, %{host_id: host_id, credential_id: credential_id, expires_at: _}} =
             CLI.run(["peach-rotate", host.id, "3600", output])

    assert host_id == host.id
    assert %File.Stat{mode: mode} = File.stat!(output)
    assert Bitwise.band(mode, 0o777) == 0o600
    token = File.read!(output)
    assert byte_size(token) == 80
    assert String.starts_with?(token, credential_id <> ".")

    assert {:ok, %{verified: true, host_id: ^host_id, credential_id: ^credential_id}} =
             CLI.run(["peach-verify", output])

    assert {:error, :peach_credential_failed} = CLI.run(["peach-rotate", host.id, "3600", output])
    assert {:ok, %{verified: true}} = CLI.run(["peach-verify", output])
    assert {:ok, %{host_id: ^host_id, revoked: true}} = CLI.run(["peach-revoke", host.id])
    assert {:error, :peach_credential_failed} = CLI.run(["peach-verify", output])
  end

  test "invalid lifetimes and unknown hosts issue no credential", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    output = Path.join(dir, "peach.token")

    assert {:error, :invalid_arguments} =
             CLI.run(["peach-rotate", Ecto.UUID.generate(), "x", output])

    assert {:error, :peach_credential_failed} =
             CLI.run(["peach-rotate", Ecto.UUID.generate(), "3600", output])

    refute File.exists?(output) and byte_size(File.read!(output)) == 80
  end
end
