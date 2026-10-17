defmodule Marshall.Control.CertificateHintsTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.FleetCertificate

  test "a recorded ACME proof hints DNS and an activation hints gateways" do
    parent = self()
    handler = "certificate-hint-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _, _, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    zone = Application.fetch_env!(:marshall, :ingress_zone)
    certificate = Ledger.create!(FleetCertificate, :enqueue, %{generation: 1, zone: zone})
    id = certificate.id

    certificate =
      certificate
      |> Ledger.update!(:bind_order, %{
        order_url: "https://ca.example.test/order/1",
        finalize_url: "https://ca.example.test/finalize/1",
        authorization_url: "https://ca.example.test/auth/1"
      })
      |> Ledger.update!(:record_proof, %{
        dns_proof: String.duplicate("p", 43),
        proof_expires_at: DateTime.add(Ledger.now(), 600)
      })

    assert_receive {:hint, :dns_snapshot, ^id}, 1_000
    refute_receive {:hint, :fleet_certificate, _}, 100

    certificate
    |> Ledger.update!(:finish_issued, %{
      chain_pem: "fixture-chain",
      fingerprint: String.duplicate("a", 64),
      expires_at: DateTime.add(Ledger.now(), 3600)
    })
    |> Ledger.update!(:activate, %{})

    assert_receive {:hint, :fleet_certificate, ^id}, 1_000
  end
end
