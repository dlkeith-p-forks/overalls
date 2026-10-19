defmodule Susan.Application do
  @moduledoc "Supervision root for the independently deployed Susan push relay."
  use Application
  require Susan.Events

  @impl true
  def start(_type, _args) do
    :ok = Susan.Privacy.install()

    with {:ok, children} <- children(Application.get_env(:susan, :runtime, :release)) do
      Supervisor.start_link(children, strategy: :rest_for_one, name: Susan.Supervisor)
    end
  end

  @doc "Process tree for the test VM (no listener) or a configured release."
  @spec children(:test | :release) ::
          {:ok, [Supervisor.child_spec() | {module(), term()} | module()]} | {:error, atom()}
  def children(:test), do: {:ok, core() ++ [{Oban, Application.fetch_env!(:susan, Oban)}]}

  def children(:release) do
    case Susan.Config.load(
           System.get_env("SUSAN_CONFIG_FILE"),
           System.get_env("CREDENTIALS_DIRECTORY")
         ) do
      {:ok, config} ->
        {:ok,
         [{Susan.Repo, config.repo}] ++
           core() ++
           [
             {Oban, Application.fetch_env!(:susan, Oban)},
             Susan.Provider.Finch,
             Supervisor.child_spec({Task, fn -> Susan.KeyringAudit.record(config.keyring) end},
               restart: :temporary
             ),
             {Bandit,
              plug: {Susan.HTTP, config},
              ip: config.bind,
              port: config.port,
              startup_log: false,
              http_options: [log_protocol_errors: false],
              thousand_island_options: [
                num_acceptors: 16,
                num_connections: 1024,
                read_timeout: 15_000
              ]}
           ]}

      {:error, reason} ->
        Susan.Events.emit("susan.startup_configuration_rejected", reason: reason)
        {:error, reason}
    end
  end

  defp core do
    test_repo = if Application.get_env(:susan, :runtime) == :test, do: [Susan.Repo], else: []

    test_repo ++
      [
        Susan.RateLimiter,
        Susan.Replay,
        Susan.SourceAddress,
        Susan.Provider.Tokens
      ]
  end
end
