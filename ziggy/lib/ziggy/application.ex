defmodule Ziggy.Application do
  @moduledoc "Supervision root for the independently packaged inference service."
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
            OverallsAntithesis.SDK.reachable("Overalls Ziggy application started")
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

  require Ziggy.Events
  @impl true
  def start(_type, _args) do
    :ok = Ziggy.Privacy.install()

    with {:ok, children} <- children(System.get_env("ZIGGY_CONFIG_FILE")) do
      harness_started(
        Supervisor.start_link(children, strategy: :rest_for_one, name: Ziggy.Supervisor)
      )
    end
  end

  @spec children(nil | binary()) :: {:ok, list()} | {:error, atom()}
  def children(nil), do: {:ok, []}

  def children(path) do
    with {:ok, config} <- Ziggy.Config.load(path) do
      {:ok,
       [
         {Ziggy.Control.Link, config.control},
         {Task.Supervisor, name: Ziggy.Tasks, max_children: 2048},
         {Finch, name: Ziggy.Finch, pools: %{default: [size: 256, count: 8]}},
         {Ziggy.Spool,
          name: Ziggy.Spool, directory: config.spool, max_requests: config.max_requests},
         {DynamicSupervisor, name: Ziggy.Leases, strategy: :one_for_one, max_children: 2048},
         {Ziggy.Catalog,
          name: Ziggy.Catalog,
          credentials: config.credentials,
          tasks: Ziggy.Tasks,
          openai_origin: config.openai_origin},
         {Ziggy.Reporter, spool: Ziggy.Spool, control: config.control}
       ] ++
         if(config.agent_enabled, do: [{Ziggy.AgentWorker, config: config}], else: []) ++
         [
           {Bandit,
            plug: {Ziggy.HTTP, config},
            ip: {:local, config.socket},
            port: 0,
            startup_log: false,
            http_options: [log_protocol_errors: false],
            thousand_island_options: [
              num_acceptors: 16,
              num_connections: 128,
              read_timeout: 30_000
            ]}
         ]}
    else
      {:error, reason} = error when is_atom(reason) ->
        Ziggy.Events.emit("ziggy.startup_configuration_rejected", reason: reason)
        error
    end
  end
end
