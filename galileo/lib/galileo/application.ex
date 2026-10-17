defmodule Galileo.Application do
  @moduledoc "Supervision root for the independently packaged integration service."
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
            OverallsAntithesis.SDK.reachable("Overalls Galileo application started")
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

  require Galileo.Events
  @impl true
  def start(_type, _args) do
    :ok = Galileo.Privacy.install()

    with {:ok, children} <- children(System.get_env("GALILEO_CONFIG_FILE")) do
      harness_started(
        Supervisor.start_link(children, strategy: :rest_for_one, name: Galileo.Supervisor)
      )
    end
  end

  # @cc [owner:ghuntley,label:security;reliability] galileo-http1-native-listener
  # A configured private listener MUST disable HTTP/2 so owner-bound lease
  # cancellation uses the reviewed pinned HTTP/1 ThousandIsland transport seam.
  @spec children(nil | binary()) :: {:ok, list()} | {:error, atom()}
  def children(nil), do: {:ok, []}

  def children(path) do
    with {:ok, config} <- Galileo.Config.load(path) do
      {:ok,
       Overalls.RequestAccounting.Producer.children(Galileo.RequestRecorder) ++
         [
           {Finch, name: Galileo.Finch, pools: %{default: [size: 256, count: 8]}},
           {Galileo.Control.Link, config.control},
           {Bandit,
            plug: {Galileo.HTTP, config},
            ip: {:local, config.socket},
            port: 0,
            startup_log: false,
            http_2_options: [enabled: false],
            http_options: [log_protocol_errors: false],
            thousand_island_options: [
              num_acceptors: 16,
              num_connections: 128,
              read_timeout: 30_000
            ]},
           {Galileo.SLO, []}
         ]}
    else
      _ ->
        Galileo.Events.emit("galileo.startup_configuration_rejected",
          reason: :invalid_configuration
        )

        {:error, :invalid_configuration}
    end
  end
end
