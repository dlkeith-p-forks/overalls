defmodule Overalls.Diagnostics.Application do
  @moduledoc false
  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    config =
      :otel_configuration.merge_with_os([])
      |> Map.merge(%{
        processors: [{Overalls.Diagnostics.Processor, %{}}],
        traces_exporter: :none,
        id_generator: Overalls.Diagnostics.IdGenerator,
        sampler: {Overalls.Diagnostics.Sampler, %{}}
      })

    metrics = %{
      id: Overalls.Diagnostics.Metrics,
      start: {Overalls.Diagnostics.Metrics, :start_link, [[]]},
      type: :worker,
      shutdown: 5000
    }

    child = %{
      id: {Overalls.Diagnostics.Tracing, :provider},
      start:
        {:otel_tracer_server_sup, :start_link,
         [:overalls_diagnostics, :otel_resource.create([]), config]},
      type: :supervisor,
      shutdown: 5000
    }

    with {:ok, supervisor} <-
           Supervisor.start_link([metrics, child],
             strategy: :one_for_one,
             name: __MODULE__.Supervisor
           ) do
      tracer =
        :otel_tracer_provider.get_tracer(:overalls_diagnostics, :overalls, "0.1.0", :undefined)

      :persistent_term.put({Overalls.Diagnostics.Tracing, :tracer}, tracer)
      {:ok, supervisor}
    end
  end
end
