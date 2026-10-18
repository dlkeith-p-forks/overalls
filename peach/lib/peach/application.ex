defmodule Peach.Application do
  use Application
  @impl true
  def start(_type, _args) do
    config = Peach.Config.load(System.get_env("PEACH_CONFIG_FILE"))

    children = [
      {Peach.Control.Link, config.control},
      {Bandit,
       plug: {Peach.HTTP, config}, ip: {:local, config.socket}, port: 0, startup_log: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Peach.Supervisor)
  end
end
