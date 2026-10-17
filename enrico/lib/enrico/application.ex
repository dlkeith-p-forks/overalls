defmodule Enrico.Application do
  @moduledoc "Independent mirror service supervision root."
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
            OverallsAntithesis.SDK.reachable("Overalls Enrico application started")
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

  require Enrico.Events

  @impl true
  def start(_type, _args) do
    :ok = Enrico.Privacy.install()

    result =
      case System.get_env("ENRICO_CONFIG_FILE") do
        nil -> Supervisor.start_link([], strategy: :one_for_one, name: Enrico.Supervisor)
        path -> start_configured(path)
      end

    harness_started(result)
  end

  defp start_configured(path) do
    with {:ok, config} <- Enrico.Config.load(path) do
      children =
        Overalls.RequestAccounting.Producer.children(Enrico.RequestRecorder) ++
          [
            {Enrico.RefreshSupervisor, config},
            Supervisor.child_spec(
              {Bandit,
               plug: {Enrico.HTTP, config},
               scheme: :https,
               ip: config.bind,
               port: config.port,
               certfile: config.certificate,
               keyfile: config.key,
               startup_log: false,
               http_options: [log_protocol_errors: false],
               http_2_options: [enabled: false],
               websocket_options: [enabled: false],
               thousand_island_options: [
                 num_acceptors: 4,
                 num_connections: 64,
                 read_timeout: 10_000
               ]},
              id: Enrico.APIListener
            ),
            Supervisor.child_spec(
              {Bandit,
               plug: {Enrico.Health, config},
               ip: {:local, config.status_socket},
               port: 0,
               startup_log: false},
              id: Enrico.HealthListener
            )
          ]

      Supervisor.start_link(children, strategy: :rest_for_one, name: Enrico.Supervisor)
    else
      _ ->
        Enrico.Events.emit("enrico.startup_rejected", reason: :invalid_configuration)
        {:error, :invalid_configuration}
    end
  end
end
