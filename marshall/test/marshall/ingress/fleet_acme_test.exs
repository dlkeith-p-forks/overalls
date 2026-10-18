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
end
