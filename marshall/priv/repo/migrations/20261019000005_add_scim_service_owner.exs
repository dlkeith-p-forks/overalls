defmodule Marshall.Repo.Migrations.AddScimServiceOwner do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO users (email, active, scim_external_id)
    VALUES ('scim-service-owner@deleted.invalid', TRUE, 'scim-service-owner')
    ON CONFLICT (email) DO NOTHING
    """
  end

  def down do
    execute "DELETE FROM users WHERE email = 'scim-service-owner@deleted.invalid'"
  end
end
