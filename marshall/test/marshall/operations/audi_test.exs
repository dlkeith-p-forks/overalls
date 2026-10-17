defmodule Marshall.Operations.AudiTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Compute.Ledger
  alias Marshall.ComputeFixtures
  alias Marshall.Ingress.{Service, Token}
  alias Marshall.Operations.{CLI, PrivateFiles}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    fixture = ComputeFixtures.host_fixture()

    %{
      host_id: fixture.host.id,
      dns: Path.join(dir, "dns"),
      rotated: Path.join(dir, "rotated"),
      gateway: Path.join(dir, "gateway"),
      failed: Path.join(dir, "failed")
    }
  end

  test "dns enrollment writes a private token, configures authority and rotates generation", c do
    assert {:ok, first} = CLI.run(["audi-dns-rotate", "fleet-dns", c.dns])
    assert first.role == :dns and is_nil(first.host_id) and first.generation == 1

    [service] = Ledger.read!(Service, name: "fleet-dns")
    assert service.addresses == [] and service.enabled

    assert {:ok, token} = PrivateFiles.read(c.dns)
    assert {:ok, digest} = Token.digest(token)
    assert service.token_hash == digest

    assert {:ok, identity} = CLI.run(["audi-dns-verify", c.dns])
    assert identity[:name] == "fleet-dns" and identity[:role] == :dns and identity[:verified]

    assert {:error, :output_exists} = CLI.run(["audi-dns-rotate", "fleet-dns", c.dns])

    assert {:ok, second} = CLI.run(["audi-dns-rotate", "fleet-dns", c.rotated])
    assert second.id == first.id and second.generation == first.generation + 1

    assert {:error, :audi_credential_failed} = CLI.run(["audi-dns-verify", c.dns])
    assert {:ok, _} = CLI.run(["audi-dns-verify", c.rotated])
  end

  test "gateway enrollment binds one host and canonical addresses", c do
    assert {:ok, gateway} =
             CLI.run([
               "audi-gateway-rotate",
               "fleet-gateway",
               c.host_id,
               "192.0.2.10,192.0.2.11",
               c.gateway
             ])

    assert gateway.role == :gateway and gateway.host_id == c.host_id

    [service] = Ledger.read!(Service, name: "fleet-gateway")
    assert service.addresses == ["192.0.2.10", "192.0.2.11"]

    assert {:ok, identity} = CLI.run(["audi-gateway-verify", c.gateway])
    assert identity[:name] == "fleet-gateway" and identity[:role] == :gateway

    assert {:ok, _} =
             CLI.run(["audi-gateway-rotate", "fleet-gateway", c.host_id, "", c.rotated])

    [rotated] = Ledger.read!(Service, name: "fleet-gateway")
    assert rotated.addresses == [] and rotated.generation == gateway.generation + 1
  end

  test "invalid gateway arguments never create authority or files", c do
    nine = Enum.join(Enum.map(1..9, &"192.0.2.#{100 + &1}"), ",")

    for addresses <- [
          "999.1.1.1",
          "192.0.2.10;192.0.2.11",
          "192.0.2.10,192.0.2.10",
          "192.0.2.10,",
          ",192.0.2.10",
          " 192.0.2.10",
          nine
        ] do
      assert {:error, :invalid_arguments} =
               CLI.run(["audi-gateway-rotate", "bad-gateway", c.host_id, addresses, c.failed])

      assert Ledger.read!(Service, name: "bad-gateway") == []
    end

    assert {:error, :invalid_arguments} =
             CLI.run(["audi-gateway-rotate", "bad-gateway", "not-a-uuid", "192.0.2.10", c.failed])

    refute File.exists?(c.failed)
  end

  test "unknown hosts and role conflicts roll back and retain the output file", c do
    assert {:error, :audi_operation_failed} =
             CLI.run([
               "audi-gateway-rotate",
               "orphan-gateway",
               Ash.UUID.generate(),
               "192.0.2.10",
               c.failed
             ])

    assert File.exists?(c.failed)
    assert Ledger.read!(Service, name: "orphan-gateway") == []

    assert {:ok, _} = CLI.run(["audi-dns-rotate", "shared-name", c.dns])

    assert {:error, :audi_operation_failed} =
             CLI.run(["audi-gateway-rotate", "shared-name", c.host_id, "192.0.2.10", c.gateway])

    assert [%{role: :dns}] = Ledger.read!(Service, name: "shared-name")
  end

  test "revoke disables the service and its credential stops authenticating", c do
    assert {:ok, _} = CLI.run(["audi-dns-rotate", "fleet-dns", c.dns])
    assert {:ok, revoked} = CLI.run(["audi-dns-revoke", "fleet-dns"])
    assert revoked[:enabled] == false
    assert {:error, :audi_credential_failed} = CLI.run(["audi-dns-verify", c.dns])

    assert {:error, :audi_operation_failed} = CLI.run(["audi-dns-revoke", "missing-name"])
    assert {:error, :audi_operation_failed} = CLI.run(["audi-gateway-revoke", "missing-name"])
  end

  test "unsafe or malformed credential files fail verification without details", c do
    assert {:ok, _} = CLI.run(["audi-dns-rotate", "fleet-dns", c.dns])
    File.chmod!(c.dns, 0o644)
    assert {:error, :audi_credential_failed} = CLI.run(["audi-dns-verify", c.dns])

    File.write!(c.gateway, "audi_service_invalid")
    File.chmod!(c.gateway, 0o600)
    assert {:error, :audi_credential_failed} = CLI.run(["audi-gateway-verify", c.gateway])
  end

  property "malformed address lists never create authority", c do
    check all(
            parts <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 12),
                min_length: 1,
                max_length: 6
              )
          ) do
      assert {:error, _} =
               CLI.run([
                 "audi-gateway-rotate",
                 "property-gateway",
                 c.host_id,
                 Enum.join(parts, ","),
                 c.failed
               ])

      assert Ledger.read!(Service, name: "property-gateway") == []
    end
  end
end
