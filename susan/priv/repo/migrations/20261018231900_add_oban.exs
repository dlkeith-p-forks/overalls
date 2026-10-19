defmodule Susan.Repo.Migrations.AddOban do
  @moduledoc "Oban job tables for the maintenance queue; jobs carry no request data."
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 1)
end
