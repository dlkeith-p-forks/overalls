defmodule Brady.InvalidBootProbe do
  @moduledoc false
  @entry_points [Brady.TLS.Certificates, Brady.Cache.Runtime, Brady.Listener, Brady.Metrics]
  @type flags :: %{
          supervisor_attempted: boolean(),
          signer_attempted: boolean(),
          cache_attempted: boolean(),
          listener_attempted: boolean(),
          metrics_attempted: boolean(),
          rejection_event: boolean()
        }

  # @cc [owner:ghuntley,label:security;verification] brady-boot-probe-test-only
  # run/0 MUST require Mix test and explicit probe opt-in. Captured arguments
  # and logger payloads MUST leave this disposable BEAM only as closed labels
  # and booleans. The real runtime config path MUST match the requested path.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "boot probe requires the explicit test environment"
    end

    unless Application.get_env(:brady, :config_file) == System.get_env("BRADY_CONFIG_FILE") do
      raise "boot probe runtime configuration mismatch"
    end

    File.cd!(System.fetch_env!("OVERALLS_PROBE_ROOT"))
    Enum.each([Supervisor | @entry_points], &Code.ensure_loaded!/1)

    initial = %{
      supervisor_attempted: false,
      signer_attempted: false,
      cache_attempted: false,
      listener_attempted: false,
      metrics_attempted: false,
      rejection_event: false
    }

    tracer = spawn_link(fn -> trace_loop(initial) end)
    :ok = :logger.add_primary_filter(:boot_probe_rejection, {&observe_rejection/2, tracer})
    :erlang.trace_pattern({Supervisor, :start_link, 2}, true, [:local])
    Enum.each(@entry_points, &:erlang.trace_pattern({&1, :start_link, 1}, true, [:local]))
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])
    result = Application.ensure_all_started(:brady)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "boot trace delivery timed out"
    end

    reference = make_ref()
    send(tracer, {:finish, self(), reference})

    flags =
      receive do
        {^reference, flags} -> flags
      after
        5_000 -> raise "boot trace collection timed out"
      end

    :erlang.trace(:all, false, [:all])

    outcome =
      case result do
        {:error, {:brady, {:invalid_configuration, {Brady.Application, :start, [:normal, []]}}}} ->
          "configuration_rejected"

        {:error,
         {:brady,
          {{:shutdown,
            {:failed_to_start_child, Brady.TLS.Certificates, :invalid_signing_credentials}},
           {Brady.Application, :start, [:normal, []]}}}} ->
          "signing_rejected"

        {:ok, _} ->
          "started"

        _ ->
          "other"
      end

    supervisor = Process.whereis(Brady.Supervisor)

    metrics_only =
      is_pid(supervisor) and
        match?(
          [{Brady.Metrics, pid, :worker, _}] when is_pid(pid),
          Supervisor.which_children(supervisor)
        )

    projection =
      Map.merge(flags, %{
        outcome: outcome,
        supervisor: is_pid(supervisor),
        metrics_only: metrics_only,
        signer: is_pid(Process.whereis(Brady.TLS.Certificates)),
        cache: is_pid(Process.whereis(Brady.Cache.Store)),
        metrics: is_pid(Process.whereis(Brady.Metrics)),
        cache_directory: File.exists?(System.fetch_env!("OVERALLS_PROBE_CACHE"))
      })

    IO.puts("BOOT_PROBE:" <> JSON.encode!(projection))
  end

  @spec observe_rejection(map(), pid()) :: :ignore
  def observe_rejection(%{meta: %{event: "brady.configuration_rejected"}}, tracer) do
    send(tracer, :rejection_event)
    :ignore
  end

  def observe_rejection(_, _), do: :ignore

  @spec trace_loop(flags()) :: :ok
  defp trace_loop(flags) do
    receive do
      {:trace, _pid, :call, {Supervisor, :start_link, [_children, options]}} ->
        attempted = flags.supervisor_attempted or Keyword.get(options, :name) == Brady.Supervisor
        trace_loop(%{flags | supervisor_attempted: attempted})

      {:trace, _pid, :call, {module, :start_link, [_options]}} when module in @entry_points ->
        field =
          case module do
            Brady.TLS.Certificates -> :signer_attempted
            Brady.Cache.Runtime -> :cache_attempted
            Brady.Listener -> :listener_attempted
            Brady.Metrics -> :metrics_attempted
          end

        trace_loop(Map.put(flags, field, true))

      :rejection_event ->
        trace_loop(%{flags | rejection_event: true})

      {:finish, caller, reference} ->
        send(caller, {reference, flags})
        :ok

      _ ->
        trace_loop(flags)
    end
  end
end

Brady.InvalidBootProbe.run()
