defmodule Brady.Application do
  @moduledoc false
  use Application

  # @cc [owner:ghuntley,label:verification] antithesis-bootstrap-reachable
  # Only a harness-built release emits this literal after successful supervision.
  # The production module has no SDK call or runtime switch.
  if System.get_env("ANTITHESIS_HARNESS") == "1" do
    Code.eval_quoted(
      quote location: :keep do
        require OverallsAntithesis.SDK

        @spec harness_started(GenServer.on_start()) :: GenServer.on_start()
        defp harness_started(result) do
          if match?({:ok, _pid}, result) and
               OverallsAntithesis.SDK.declare_catalog([__MODULE__]) == :written do
            OverallsAntithesis.SDK.reachable("Overalls Brady application started")
          end

          result
        end
      end,
      [],
      __ENV__
    )
  else
    @spec harness_started(GenServer.on_start()) :: GenServer.on_start()
    defp harness_started(result), do: result
  end

  require Brady.Events

  @impl true
  def start(_type, _args) do
    :ok = Overalls.Diagnostics.Privacy.install(Brady.Events, :brady)

    with {:ok, children} <- runtime_children(Application.get_env(:brady, :config_file)) do
      harness_started(
        Supervisor.start_link(
          Overalls.RequestAccounting.Producer.children(Brady.RequestRecorder) ++
            children ++ [{Brady.Metrics, Application.get_env(:brady, :metrics, [])}],
          strategy: :one_for_one,
          name: Brady.Supervisor
        )
      )
    else
      {:error, reason} ->
        Brady.Events.emit("brady.configuration_rejected", reason: reason)
        {:error, reason}
    end
  end

  defp runtime_children(nil), do: {:ok, []}

  defp runtime_children(path) do
    with {:ok, config} <- Brady.Config.load(path) do
      proxy = Brady.Config.proxy(config)

      {:ok,
       [
         {Brady.TLS.Certificates,
          name: Brady.TLS.Certificates, certfile: config.certfile, keyfile: config.keyfile},
         {Brady.Cache.Runtime,
          name: Brady.Cache.Store,
          root: config.cache_directory,
          limits: config.limits,
          ready: fn -> Brady.Cache.Pressure.read(config) end},
         {Brady.Listener, scheme: :http, port: 15080, config: proxy},
         {Brady.Listener, scheme: :https, port: 15443, config: proxy}
       ]}
    end
  end
end
