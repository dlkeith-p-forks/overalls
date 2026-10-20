defmodule Marshall.Ingress.FleetACMETest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Ingress.ACME.{AccountKey, Request}
  alias Marshall.Ingress.FleetACMEConfig

  test "CSR recovery preserves the same wildcard key and exact DER" do
    assert {:ok, request} = Request.generate("apps.example.test")

    assert {:ok, restored} =
             Request.restore("apps.example.test", request.der, request.private_key_pem)

    assert restored.der == request.der
    assert restored.private_key_pem == request.private_key_pem

    assert {:error, :invalid_certificate_request} =
             Request.restore("other.example.test", request.der, request.private_key_pem)
  end

  property "account identity is derived from the saved scalar", test_cases: 100 do
    bytes = draw("bytes", binary(length: 32))

    case AccountKey.from_private(bytes) do
      {:ok, key} ->
        assert {:ok, recovered} = AccountKey.from_private(key.private)
        assert recovered.thumbprint == key.thumbprint
        refute inspect(key) =~ Base.encode16(bytes, case: :lower)

      {:error, :invalid_account_key} ->
        :ok
    end
  end

  test "issuer is disabled when unselected and rejects partial selection" do
    assert {:ok, nil} = FleetACMEConfig.from_env(%{})

    assert {:error, :invalid_configuration} =
             FleetACMEConfig.from_env(%{
               "MARSHALL_FLEET_ACME_DIRECTORY" => "https://ca.example.test/dir"
             })
  end

  @tag :tmp_dir
  test "issuer accepts one to eight distinct DNS peers", %{tmp_dir: dir} do
    ca = Path.join(dir, "ca.pem")
    roots = Path.join(dir, "roots.pem")
    File.write!(ca, "ca")
    File.write!(roots, "roots")

    env = fn peers ->
      %{
        "MARSHALL_FLEET_ACME_DIRECTORY" => "https://ca.example.test/dir",
        "MARSHALL_INGRESS_ZONE" => "apps.example.test",
        "MARSHALL_FLEET_ACME_ISSUER_CA_FILE" => ca,
        "MARSHALL_FLEET_ACME_ROOTS_FILE" => roots,
        "MARSHALL_FLEET_ACME_NAMESERVERS" => JSON.encode!(peers),
        "MARSHALL_FLEET_ACME_ACCEPT_TERMS" => "true"
      }
    end

    peer = fn n -> %{"address" => "192.0.2.#{n}", "port" => 53} end

    assert {:ok, %{nameservers: [{{192, 0, 2, 1}, 53}]}} =
             FleetACMEConfig.from_env(env.([peer.(1)]))

    assert {:ok, %{nameservers: peers}} = FleetACMEConfig.from_env(env.(Enum.map(1..8, peer)))
    assert length(peers) == 8

    for peers <- [[], Enum.map(1..9, peer), [peer.(1), peer.(1)]] do
      assert {:error, :invalid_configuration} = FleetACMEConfig.from_env(env.(peers))
    end
  end
end
