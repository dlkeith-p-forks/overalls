defmodule Marshall.Repo.Migrations.EndpointEditorPortCheck do
  @moduledoc "ADR-0159 Push 4 (B7): PostgreSQL refuses endpoints on the reserved Editor port."
  use Ecto.Migration

  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create constraint(:ingress_endpoints, :ingress_endpoint_not_editor_port,
             check: "primary_port <> 4444"
           )

    :ok
  end

  @spec down() :: :ok
  def down do
    drop_if_exists constraint(:ingress_endpoints, :ingress_endpoint_not_editor_port)
    :ok
  end
end
