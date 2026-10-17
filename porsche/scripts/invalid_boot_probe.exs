defmodule Porsche.InvalidBootProbe do
  @moduledoc false
  @entry_points [Porsche.Listener, Porsche.StatusServer, Porsche.Observability]
  @base_names [
    Porsche.SSH.Proofs,
    Porsche.SSH.Sessions,
    Porsche.SSH.Connections,
    Porsche.SSH.Commands,
    Porsche.Observability
  ]
  @type flags :: %{
          supervisor_attempted: boolean(),
          listener_attempted: boolean(),
          status_attempted: boolean(),
          observability_attempted: boolean()
        }

  # @cc [owner:ghuntley,label:security;verification] porsche-boot-probe-test-only
  # run/0 MUST require Mix test and explicit opt-in. Captured startup arguments
  # MUST leave this disposable BEAM only as closed labels and booleans.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "boot probe requires the explicit test environment"
    end

    File.cd!(System.fetch_env!("OVERALLS_PROBE_ROOT"))
    Enum.each([Supervisor | @entry_points], &Code.ensure_loaded!/1)

    initial = %{
      supervisor_attempted: false,
      listener_attempted: false,
      status_attempted: false,
      observability_attempted: false
    }

    tracer = spawn_link(fn -> trace_loop(initial) end)
    :erlang.trace_pattern({Supervisor, :start_link, 2}, true, [:local])
    Enum.each(@entry_points, &:erlang.trace_pattern({&1, :start_link, 1}, true, [:local]))
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])
    result = Application.ensure_all_started(:porsche)
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
        {:error,
         {:porsche,
          {:invalid_runtime_configuration, {Porsche.Application, :start, [:normal, []]}}}} ->
          "rejected"

        {:ok, _} ->
          "started"

        _ ->
          "other"
      end

    supervisor = Process.whereis(Porsche.Supervisor)

    projection =
      Map.merge(flags, %{
        outcome: outcome,
        supervisor: is_pid(supervisor),
        base_present: Enum.any?(@base_names, &is_pid(Process.whereis(&1))),
        base_only: base_only?(supervisor),
        listener: is_pid(Process.whereis(Porsche.Listener)),
        socket: File.exists?(System.fetch_env!("OVERALLS_PROBE_SOCKET"))
      })

    IO.puts("BOOT_PROBE:" <> JSON.encode!(projection))
  end

  @spec base_only?(pid() | nil) :: boolean()
  defp base_only?(supervisor) when is_pid(supervisor) do
    children = Supervisor.which_children(supervisor)
    pids = Enum.map(children, fn {_id, pid, _type, _modules} -> pid end)

    length(pids) == 5 and
      Enum.all?(@base_names, fn name ->
        pid = Process.whereis(name)
        is_pid(pid) and pid in pids
      end)
  end

  defp base_only?(_), do: false

  @spec trace_loop(flags()) :: :ok
  defp trace_loop(flags) do
    receive do
      {:trace, _pid, :call, {Supervisor, :start_link, [_children, options]}} ->
        attempted =
          flags.supervisor_attempted or Keyword.get(options, :name) == Porsche.Supervisor

        trace_loop(%{flags | supervisor_attempted: attempted})

      {:trace, _pid, :call, {module, :start_link, [_options]}} when module in @entry_points ->
        field =
          case module do
            Porsche.Listener -> :listener_attempted
            Porsche.StatusServer -> :status_attempted
            Porsche.Observability -> :observability_attempted
          end

        trace_loop(Map.put(flags, field, true))

      {:finish, caller, reference} ->
        send(caller, {reference, flags})
        :ok

      _ ->
        trace_loop(flags)
    end
  end
end

Porsche.InvalidBootProbe.run()
