defmodule Marshall.FleetCertificateFixtures do
  @moduledoc false
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{FleetCertificate, FleetCertificateInstallation}

  @type gateway :: %{
          required(:id) => binary(),
          required(:host_id) => binary(),
          required(:generation) => pos_integer()
        }

  # @cc [owner:ghuntley,label:verification;security] wildcard-route-test-evidence
  # Route fixtures MUST create an active wildcard and a receipt for the exact
  # gateway generation. A fabricated per-VM fingerprint is not route evidence.
  @spec install!(gateway(), DateTime.t(), binary()) :: FleetCertificate.t()
  def install!(%{id: _, host_id: _, generation: _} = service, expires_at, fingerprint) do
    zone = Application.fetch_env!(:marshall, :ingress_zone)

    certificate =
      Ledger.create!(FleetCertificate, :enqueue, %{generation: 1, zone: zone})
      |> Ledger.update!(:bind_order, %{
        order_url: "https://ca.example.test/order/1",
        finalize_url: "https://ca.example.test/finalize/1",
        authorization_url: "https://ca.example.test/auth/1"
      })
      |> Ledger.update!(:finish_issued, %{
        chain_pem: "fixture-chain",
        fingerprint: fingerprint,
        expires_at: expires_at
      })
      |> Ledger.update!(:activate, %{})

    Ledger.create!(FleetCertificateInstallation, :record, %{
      host_id: service.host_id,
      service_id: service.id,
      service_generation: service.generation,
      zone: certificate.zone,
      generation: certificate.generation,
      fingerprint: fingerprint
    })

    certificate
  end
end
