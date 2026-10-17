defmodule Marshall.Repo.Migrations.PeerWebStreamBinding do
  use Ecto.Migration

  def up do
    alter table(:ingress_web_streams) do
      add :peer_integration_id,
          references(:galileo_integrations,
            column: :id,
            name: "ingress_web_streams_peer_integration_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      add :peer_source_vm_id,
          references(:compute_virtual_machines,
            column: :id,
            name: "ingress_web_streams_peer_source_vm_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create constraint(:ingress_web_streams, :ingress_web_stream_peer_binding,
             check: """
               (peer_integration_id IS NULL AND peer_source_vm_id IS NULL) OR
               (peer_integration_id IS NOT NULL AND peer_source_vm_id IS NOT NULL)
             """
           )
  end

  def down do
    drop_if_exists constraint(:ingress_web_streams, :ingress_web_stream_peer_binding)

    drop constraint(:ingress_web_streams, "ingress_web_streams_peer_source_vm_id_fkey")
    drop constraint(:ingress_web_streams, "ingress_web_streams_peer_integration_id_fkey")

    alter table(:ingress_web_streams) do
      remove :peer_source_vm_id
      remove :peer_integration_id
    end
  end
end
