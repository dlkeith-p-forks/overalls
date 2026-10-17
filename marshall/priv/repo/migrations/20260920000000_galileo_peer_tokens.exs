defmodule Marshall.Repo.Migrations.GalileoPeerTokens do
  use Ecto.Migration

  def up do
    create table(:galileo_peer_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :digest, :binary, null: false

      add :source_vm_id,
          references(:compute_virtual_machines,
            type: :uuid,
            name: "galileo_peer_tokens_source_vm_id_fkey"
          ),
          null: false

      add :integration_id,
          references(:galileo_integrations,
            type: :uuid,
            name: "galileo_peer_tokens_integration_id_fkey"
          ),
          null: false

      add :integration_name, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:galileo_peer_tokens, [:digest], name: "galileo_peer_tokens_digest_index")

    create index(:galileo_peer_tokens, [:expires_at],
             name: "galileo_peer_tokens_expires_at_index"
           )

    create constraint(:galileo_peer_tokens, :galileo_peer_tokens_digest_size,
             check: "octet_length(digest) = 32"
           )

    create constraint(:galileo_peer_tokens, :galileo_peer_tokens_name_size,
             check: "octet_length(integration_name) BETWEEN 1 AND 40"
           )
  end

  def down do
    drop table(:galileo_peer_tokens)
  end
end
