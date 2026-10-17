defmodule Marshall.Repo.Migrations.DurableGuestIdentities do
  use Ecto.Migration

  @spec up() :: :ok
  def up do
    create constraint(:account_guest_accounts, :account_guest_accounts_username_uid,
             check: "username = 'u' || uid::text"
           )

    :ok
  end

  @spec down() :: no_return()
  def down do
    raise "durable guest identity cutover cannot restore mailbox-derived names"
  end
end
