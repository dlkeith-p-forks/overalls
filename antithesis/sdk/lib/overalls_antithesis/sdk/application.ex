defmodule OverallsAntithesis.SDK.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([OverallsAntithesis.SDK.Writer],
      strategy: :one_for_one,
      name: OverallsAntithesis.SDK.Supervisor
    )
  end
end
