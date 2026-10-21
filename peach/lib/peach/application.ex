defmodule Peach.Application do
  @moduledoc "Supervision root for the guest reflection service."
  use Application
  require Peach.Events

  @impl true
  def start(_type, _args) do
    :ok = Peach.Privacy.install()

    with {:ok, children} <- children(System.get_env("PEACH_CONFIG_FILE")) do
      Supervisor.start_link(children, strategy: :rest_for_one, name: Peach.Supervisor)
    end
  end

  # @cc [owner:ghuntley,label:deployment] peach-explicit-configuration
  # Without PEACH_CONFIG_FILE the application starts no listener or control
  # link (tests and tooling). A configured path MUST load strictly; any
  # rejection stops startup with a fixed reason and no path or value.
  @spec children(nil | binary()) :: {:ok, list()} | {:error, :invalid_configuration}
  def children(nil), do: {:ok, []}

  def children(path) do
    case Peach.Config.load(path) do
      {:ok, config} ->
        {:ok,
         [
           {Peach.Control.Link, config.control},
           {Bandit,
            plug: {Peach.HTTP, config},
            ip: {:local, config.socket},
            port: 0,
            startup_log: false,
            http_2_options: [enabled: false],
            http_options: [log_protocol_errors: false],
            thousand_island_options: [
              num_acceptors: 4,
              num_connections: 128,
              read_timeout: 10_000
            ]}
         ]}

      {:error, reason} ->
        Peach.Events.emit("peach.startup_configuration_rejected", reason: reason)
        {:error, reason}
    end
  end
end
