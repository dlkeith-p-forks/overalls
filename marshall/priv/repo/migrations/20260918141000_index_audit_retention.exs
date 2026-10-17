defmodule Marshall.Repo.Migrations.IndexAuditRetention do
  use Ecto.Migration

  @tables ~w(access_grants_versions compute_clone_requests_versions compute_evacuation_items_versions compute_evacuations_versions compute_host_credentials_versions compute_host_drains_versions compute_images_versions compute_virtual_machines_versions fleet_credentials_versions inference_credentials_versions inference_requests_versions ingress_endpoints_versions ingress_issuances_versions ingress_routes_versions ingress_services_versions ingress_sessions_versions ingress_web_credentials_versions ingress_web_logins_versions ingress_web_streams_versions ssh_keys_versions)a
  def change do
    for table <- @tables do
      create index(table, [:version_inserted_at, :id], name: "#{table}_retention_index")
    end
  end
end
