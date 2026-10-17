defmodule Marshall.Operations.SSHGatewayTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Operations.{CLI, PrivateFiles}
  alias Marshall.SSH
  alias Marshall.SSH.{Gateway, Token}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    %{first: Path.join(dir, "first"), second: Path.join(dir, "second")}
  end

  test "private preparation, replay, rotation and disabling preserve Ash authority", c do
    assert {:ok, %{prepared: true}} = CLI.run(["gateway-prepare", c.first])
    assert Ledger.read!(Gateway) == []
    assert {:ok, first} = PrivateFiles.read(c.first)
    assert {:ok, first_hash} = Token.digest(first, :gateway)
    assert {:error, :output_exists} = CLI.run(["gateway-prepare", c.first])
    assert {:ok, ^first} = PrivateFiles.read(c.first)

    assert {:ok, gateway} = CLI.run(["gateway-configure", "edge-one", c.first])
    assert {:ok, ^gateway} = CLI.run(["gateway-configure", "edge-one", c.first])
    assert [%{token_hash: ^first_hash}] = Ledger.read!(Gateway)
    assert Map.keys(gateway) |> Enum.sort() == [:enabled, :generation, :id, :name]

    blob = <<11::32, "ssh-ed25519", 32::32, 1::256>>
    key = "ssh-ed25519 " <> Base.encode64(blob)

    assert {:ok, opened} =
             SSH.open_session(%{gateway_token: first, public_key: key},
               actor: SystemActor.compute()
             )

    assert {:ok, %{prepared: true}} = CLI.run(["gateway-prepare", c.second])
    assert {:ok, rotated} = CLI.run(["gateway-configure", "edge-one", c.second])
    assert rotated.id == gateway.id
    assert rotated.generation == gateway.generation + 1
    assert {:ok, second} = PrivateFiles.read(c.second)

    for token <- [first, second] do
      assert {:error, _} =
               SSH.session_status(%{gateway_token: token, session_token: opened.session_token},
                 actor: SystemActor.compute()
               )
    end

    assert {:ok, %{enabled: false}} = CLI.run(["gateway-disable", gateway.id])

    assert {:error, _} =
             SSH.open_session(%{gateway_token: second, public_key: key},
               actor: SystemActor.compute()
             )
  end

  property "malformed private credential contents never alter gateway authority", c do
    check all(bytes <- binary(max_length: 256)) do
      File.write!(c.first, "invalid:" <> bytes)
      File.chmod!(c.first, 0o600)
      assert {:error, :invalid_gateway_file} = CLI.run(["gateway-configure", "edge", c.first])
      assert Ledger.read!(Gateway) == []
    end
  end

  test "bootstrap ensure preserves identity and refuses rotation or resurrection", c do
    alias Marshall.Operations.SSHGateway
    assert {:ok, _} = SSHGateway.prepare(c.first)
    assert {:ok, first} = PrivateFiles.read(c.first)
    assert {:ok, first_hash} = Token.digest(first, :gateway)
    assert {:ok, gateway} = SSHGateway.ensure("inner-porsche", c.first)
    assert {:ok, ^gateway} = SSHGateway.ensure("inner-porsche", c.first)

    assert {:error, _} =
             SSH.ensure_gateway(%{name: "inner-porsche", token: first},
               actor: Marshall.ComputeFixtures.user()
             )

    assert {:ok, _} = SSHGateway.prepare(c.second)
    assert {:error, :gateway_operation_failed} = SSHGateway.ensure("inner-porsche", c.second)
    assert [%{token_hash: ^first_hash, generation: 1, enabled: true}] = Ledger.read!(Gateway)
    assert {:ok, %{enabled: false}} = SSHGateway.disable(gateway.id)
    assert {:error, :gateway_operation_failed} = SSHGateway.ensure("inner-porsche", c.first)
    assert [%{token_hash: ^first_hash, generation: 2, enabled: false}] = Ledger.read!(Gateway)
    File.rm!(c.first)
    assert {:error, :invalid_gateway_file} = SSHGateway.ensure("inner-porsche", c.first)
  end

  test "unsafe credentials and invalid actions return fixed errors", c do
    assert {:ok, _} = CLI.run(["gateway-prepare", c.first])
    File.chmod!(c.first, 0o644)
    assert {:error, :invalid_gateway_file} = CLI.run(["gateway-configure", "edge", c.first])
    assert {:error, :gateway_operation_failed} = CLI.run(["gateway-disable", "invalid"])
    assert Ledger.read!(Gateway) == []
  end
end
