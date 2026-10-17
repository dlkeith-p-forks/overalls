defmodule Enrico.RefreshSupervisor do
  @moduledoc "One lifetime for mirror admission state and supervised refresh owners."
  use Supervisor

  @spec start_link(Enrico.Config.t()) :: Supervisor.on_start()
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  # @cc [owner:ghuntley,label:recovery;capacity] refresh-owner-supervision
  # Admission state and refresh workers MUST share a restart lifetime. Neither
  # Manager nor task-supervisor failure may leave workers executing under a
  # replacement Manager. Live task children MUST remain bounded to the same
  # admission ceiling, including the interval between result and process exit.
  @impl true
  def init(config) do
    Supervisor.init(
      [
        {Task.Supervisor, name: Enrico.Tasks, max_children: Enrico.Manager.refresh_limit()},
        {Enrico.Manager, config}
      ],
      strategy: :one_for_all
    )
  end
end
