defmodule OverallsProtocol.FleetCertificateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.FleetCertificate

  @host "11111111-1111-4111-8111-111111111111"
  @zone "apps.example.test"

  test "fetch and acknowledgement envelopes are closed" do
    assert {:ok, %{}} = FleetCertificate.request("fleet-certificate", %{"version" => 1})

    assert {:error, :invalid_message} =
             FleetCertificate.request("fleet-certificate", %{
               "version" => 1,
               "host_id" => @host
             })

    assert {:ok, %{generation: 2}} =
             FleetCertificate.request("fleet-certificate-ack", %{
               "version" => 1,
               "generation" => 2,
               "fingerprint" => String.duplicate("a", 64)
             })
  end

  property "malformed acknowledgement fingerprints never become typed requests" do
    check all(bytes <- binary(min_length: 0, max_length: 90), max_runs: 100) do
      unless byte_size(bytes) == 64 and String.valid?(bytes) and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, bytes) do
        assert {:error, :invalid_message} =
                 FleetCertificate.request("fleet-certificate-ack", %{
                   "version" => 1,
                   "generation" => 1,
                   "fingerprint" => bytes
                 })
      end
    end
  end

  test "response binds host, zone, bounded material and expiry" do
    bundle = %{
      "host_id" => @host,
      "zone" => @zone,
      "generation" => 7,
      "fingerprint" => String.duplicate("b", 64),
      "expires_at" => DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601(),
      "chain_pem" => "certificate",
      "private_key_pem" => "key"
    }

    assert {:ok, %{generation: 7}} =
             FleetCertificate.response(
               "fleet-certificate",
               %{"version" => 1, "bundle" => bundle},
               @host,
               @zone
             )

    assert {:error, :invalid_message} =
             FleetCertificate.response(
               "fleet-certificate",
               %{"version" => 1, "bundle" => bundle},
               @host,
               "wrong.example"
             )

    assert {:error, :invalid_message} =
             FleetCertificate.response(
               "fleet-certificate",
               %{
                 "version" => 1,
                 "bundle" => %{bundle | "private_key_pem" => String.duplicate("x", 16_385)}
               },
               @host,
               @zone
             )
  end
end
