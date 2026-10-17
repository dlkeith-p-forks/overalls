defmodule Enrico.InvalidBootProbe do
  @moduledoc false
  @entry_points [Task.Supervisor, Bandit, Enrico.Manager]

  # @cc [owner:ghuntley,label:verification;security] enrico-boot-probe-test-only
  # run/0 MUST require Mix test and explicit probe opt-in before starting Enrico.
  # Captured calls and logger payloads MUST leave this disposable BEAM only as
  # closed outcome labels and booleans, without arguments or payload bytes.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "boot probe requires the explicit test environment"
    end

    File.cd!(System.fetch_env!("OVERALLS_PROBE_ROOT"))
    Enum.each([Supervisor | @entry_points], &Code.ensure_loaded!/1)
    tracer = spawn_link(fn -> trace_loop(false, false, false) end)
    :ok = :logger.add_primary_filter(:boot_probe_rejection, {&observe_rejection/2, tracer})
    :erlang.trace_pattern({Supervisor, :start_link, 2}, true, [:local])
    Enum.each(@entry_points, &:erlang.trace_pattern({&1, :start_link, 1}, true, [:local]))
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])

    result = Application.ensure_all_started(:enrico)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "boot trace delivery timed out"
    end

    reference = make_ref()
    send(tracer, {:finish, self(), reference})

    {attempted, serving, rejection} =
      receive do
        {^reference, attempted, serving, rejection}
        when is_boolean(attempted) and is_boolean(serving) and is_boolean(rejection) ->
          {attempted, serving, rejection}
      after
        5_000 -> raise "boot trace collection timed out"
      end

    :erlang.trace(:all, false, [:all])

    outcome =
      case result do
        {:error, {:enrico, {:invalid_configuration, {Enrico.Application, :start, [:normal, []]}}}} ->
          "rejected"

        {:ok, _applications} ->
          "started"

        _ ->
          "other"
      end

    IO.puts(
      "BOOT_PROBE:" <>
        JSON.encode!(%{
          outcome: outcome,
          start_attempted: attempted or serving,
          serving_attempted: serving,
          rejection_event: rejection,
          supervisor: is_pid(Process.whereis(Enrico.Supervisor)),
          empty_supervisor:
            is_pid(Process.whereis(Enrico.Supervisor)) and
              Supervisor.which_children(Enrico.Supervisor) == [],
          tasks: is_pid(Process.whereis(Enrico.Tasks)),
          manager: is_pid(Process.whereis(Enrico.Manager)),
          socket: File.exists?(System.fetch_env!("OVERALLS_PROBE_SOCKET"))
        })
    )
  end

  @spec observe_rejection(map(), pid()) :: :ignore
  def observe_rejection(%{meta: %{event: "enrico.startup_rejected"}}, tracer) do
    send(tracer, :rejection_event)
    :ignore
  end

  def observe_rejection(_, _), do: :ignore

  @spec trace_loop(boolean(), boolean(), boolean()) :: :ok
  defp trace_loop(attempted, serving, rejection) do
    receive do
      {:trace, _pid, :call, {Supervisor, :start_link, [_children, options]}} ->
        trace_loop(
          attempted or Keyword.get(options, :name) == Enrico.Supervisor,
          serving,
          rejection
        )

      {:trace, _pid, :call, {Task.Supervisor, :start_link, [options]}} ->
        trace_loop(attempted, serving or Keyword.get(options, :name) == Enrico.Tasks, rejection)

      {:trace, _pid, :call, {module, :start_link, [_options]}} when module in @entry_points ->
        trace_loop(attempted, true, rejection)

      :rejection_event ->
        trace_loop(attempted, serving, true)

      {:finish, caller, reference} ->
        send(caller, {reference, attempted, serving, rejection})
        :ok

      _ ->
        trace_loop(attempted, serving, rejection)
    end
  end
end

Enrico.InvalidBootProbe.run()
