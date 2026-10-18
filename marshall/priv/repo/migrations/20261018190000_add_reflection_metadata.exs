defmodule Marshall.Repo.Migrations.AddReflectionMetadata do
  use Ecto.Migration

  def change do
    alter table(:compute_virtual_machines) do
      add :labels, {:array, :string}, null: false, default: []
      add :comment, :text, null: false, default: ""
    end

    alter table(:galileo_integrations) do
      add :comment, :text, null: false, default: ""
    end

    create constraint(:compute_virtual_machines, :compute_vm_labels_limit,
      check: "cardinality(labels) <= 32")

    create constraint(:compute_virtual_machines, :compute_vm_comment_limit,
      check: "octet_length(comment) <= 2048")

    create constraint(:galileo_integrations, :galileo_comment_limit,
      check: "octet_length(comment) <= 2048")
  end
end
