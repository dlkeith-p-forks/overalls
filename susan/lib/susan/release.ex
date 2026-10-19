defmodule Susan.Release do
  @moduledoc """
  Release commands. Migrations run as a separate command before start:

      bin/susan eval 'Susan.Release.migrate()'

  The command reads the same `SUSAN_CONFIG_FILE` and `$CREDENTIALS_DIRECTORY`
  as the service, so the database URL is never passed on a command line.
  """

  @spec migrate() :: :ok
  def migrate do
    {:ok, _} = Application.ensure_all_started([:ssl, :crypto, :postgrex, :ecto_sql])

    case Susan.Config.load(
           System.get_env("SUSAN_CONFIG_FILE"),
           System.get_env("CREDENTIALS_DIRECTORY")
         ) do
      {:ok, config} ->
        Application.put_env(
          :susan,
          Susan.Repo,
          Keyword.merge(Application.get_env(:susan, Susan.Repo, []), config.repo)
        )

        {:ok, _, _} =
          Ecto.Migrator.with_repo(Susan.Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))

        :ok

      {:error, _} ->
        raise "invalid Susan runtime configuration"
    end
  end
end
