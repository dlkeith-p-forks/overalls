defmodule Marshall.Ingress do
  @moduledoc "Durable workload ingress identity and access policy for Audi."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Ingress.Relay do
      define :consume_relay, action: :consume_connection
      define :renew_relay, action: :renew_connection
    end

    resource Marshall.Ingress.EditorAssetsReceipt do
      define :report_editor_assets, action: :report
    end

    resource Marshall.Ingress.FleetCertificateInstallation

    resource Marshall.Ingress.FleetCertificate do
      define :certificate_audit, action: :audit
      define :rotate_fleet_certificate, action: :rotate_for_admin
      define :deliver_fleet_certificate, action: :deliver
      define :acknowledge_fleet_certificate, action: :acknowledge
    end

    resource Marshall.Ingress.FleetCertificateAccount

    resource Marshall.Ingress.EnvironmentStream do
      define :open_nested, action: :open_nested
      define :renew_nested, action: :renew_nested
      define :close_nested, action: :close_nested
    end

    resource Marshall.Ingress.Environment do
      define :current_nested_ssh, action: :current_ssh
    end

    resource Marshall.Ingress.EnvironmentPublication

    resource Marshall.Ingress.WebLogin do
      define :begin_web_login, action: :begin_login
      define :authorize_web_login, action: :authorize_login
      define :exchange_web_login, action: :exchange_login
    end

    resource Marshall.Ingress.WebStream do
      define :open_web, action: :open_web
      define :open_peer_web, action: :open_peer_web
      define :renew_web, action: :renew_web
      define :close_web, action: :close_web
    end

    resource Marshall.Ingress.WebCredential

    resource Marshall.Ingress.Publication do
      define :dns_snapshot, action: :snapshot
    end

    resource Marshall.Ingress.Route do
      define :report_ready_route, action: :report_ready
      define :current_route, action: :current
    end

    resource Marshall.Ingress.Session do
      define :ssh_key_status, action: :ssh_key_status
      define :open_ssh, action: :open_ssh
      define :renew_ssh, action: :renew_ssh
      define :close_ssh, action: :close_ssh
    end

    resource Marshall.Ingress.Service do
      define :open_connection, action: :open_connection
      define :gateway_catalog, action: :catalog
      define :configure_service, action: :configure
      define :ensure_service, action: :ensure
      define :disable_service, action: :disable
      define :service_identity, action: :identity
      define :publish_host_key, action: :publish_host_key
    end

    resource Marshall.Ingress.Endpoint do
      define :configure_endpoint, action: :configure
      define :get_endpoint, action: :get_for_user
      define :get_ssh_endpoint, action: :get_for_ssh
    end
  end
end
