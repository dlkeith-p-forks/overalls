defmodule Brady.Cache.Runtime do
  @moduledoc "Independent cache supervision; storage failure cannot stop proxy listeners."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: Brady.Cache.Workers, strategy: :one_for_one},
        {Brady.Cache.Recovery,
         workers: Brady.Cache.Workers,
         store: Keyword.delete(opts, :ready),
         ready: Keyword.fetch!(opts, :ready)}
      ],
      strategy: :rest_for_one
    )
  end
end
