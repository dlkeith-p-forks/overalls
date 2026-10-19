defmodule Porsche.Application do
  @moduledoc "Independent management gateway application; domain authority remains in Marshall."
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
            OverallsAntithesis.SDK.reachable("Overalls Porsche application started")
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

  @impl true
  def start(_type, _args) do
    :ok = Porsche.OTPReports.install()
    :ok = Porsche.Privacy.install()

    children =
      Overalls.RequestAccounting.Producer.children(Porsche.RequestRecorder) ++
        [
          {Registry, keys: :unique, name: Porsche.SSH.Proofs},
          {Registry, keys: :unique, name: Porsche.SSH.Sessions},
          Porsche.Watchers,
          {DynamicSupervisor,
           strategy: :one_for_one, name: Porsche.SSH.Connections, max_children: 4096},
          {Task.Supervisor, name: Porsche.SSH.Commands, max_children: 4096},
          {DynamicSupervisor,
           strategy: :one_for_one, name: Porsche.Terminal.Attachments, max_children: 4096}
        ]

    with {:ok, serving} <- listener_children(System.get_env("PORSCHE_CONFIG_FILE")) do
      harness_started(
        Supervisor.start_link(children ++ serving ++ [Porsche.Observability],
          strategy: :rest_for_one,
          name: Porsche.Supervisor
        )
      )
    end
  end

  # @cc [owner:ghuntley,label:security] porsche-configured-startup-fails-closed
  # A configured runtime MUST fail startup if its config or private credentials
  # cannot be validated. It MUST NOT silently fall back to an unconfigured service.
  @spec listener_children(binary() | nil) :: {:ok, [{module(), keyword()}]} | {:error, atom()}
  def listener_children(nil), do: {:ok, []}

  def listener_children(path) do
    case Porsche.Config.load(path) do
      {:ok, options} ->
        {path, listener_options} = Keyword.pop(options, :status_socket)

        status =
          if path, do: [{Porsche.StatusServer, [path: path, client: options[:client]]}], else: []

        {:ok,
         [{Porsche.Control.Link, options[:client]}, {Porsche.Listener, listener_options}] ++
           status}

      _ ->
        {:error, :invalid_runtime_configuration}
    end
  end
end
