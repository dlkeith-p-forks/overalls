defmodule Marshall.Repo.Migrations.MessageBoards do
  use Ecto.Migration

  def change do
    create table(:message_boards, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :profile, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:message_boards, [:user_id, :profile])

    create table(:message_board_posts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :board_id, references(:message_boards, type: :uuid, on_delete: :delete_all), null: false
      add :author_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vm_id, references(:compute_virtual_machines, type: :uuid, on_delete: :delete_all)
      add :thread_id, references(:threads, type: :uuid, on_delete: :delete_all)
      add :root_id, :uuid, null: false
      add :request_key, :text, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:message_board_posts, [:board_id, :author_id, :request_key])
    create index(:message_board_posts, [:board_id, :inserted_at])
    create index(:message_board_posts, [:vm_id])
    create index(:message_board_posts, [:thread_id])
    create index(:message_board_posts, [:root_id, :inserted_at])
  end
end
