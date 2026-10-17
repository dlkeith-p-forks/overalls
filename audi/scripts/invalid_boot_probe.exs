defmodule Audi.InvalidBootProbe do
  @moduledoc false
  @listeners [
    Audi.SSH.Listener,
    Audi.HTTP.Listener,
    Audi.DNS.Server,
    Audi.Private.Listener,
    Audi.StatusServer
  ]

  # @cc [owner:ghuntley,label:verification;security] audi-boot-probe-test-only
  # run/0 MUST require Mix test and explicit probe opt-in before starting Audi.
  # Trace and logger observations MUST leave this disposable BEAM only as closed
  # outcome labels and booleans, without captured arguments or logger payloads.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "boot probe requires the explicit test environment"
    end

    Enum.each([Supervisor | @listeners], &Code.ensure_loaded!/1)
    tracer = spawn_link(fn -> trace_loop(false, false) end)
    :ok = :logger.add_primary_filter(:boot_probe_rejection, {&observe_rejection/2, tracer})
    :erlang.trace_pattern({Supervisor, :start_link, 2}, true, [:local])
    Enum.each(@listeners, &:erlang.trace_pattern({&1, :start_link, 1}, true, [:local]))
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])

    result = Application.ensure_all_started(:audi)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "boot trace delivery timed out"
    end

    reference = make_ref()
    send(tracer, {:finish, self(), reference})

    {attempted, rejection} =
      receive do
        {^reference, attempted, rejection} when is_boolean(attempted) and is_boolean(rejection) ->
          {attempted, rejection}
      after
        5_000 -> raise "boot trace collection timed out"
      end

    :erlang.trace(:all, false, [:all])

    outcome =
      case result do
        {:error,
         {:audi, {:invalid_runtime_configuration, {Audi.Application, :start, [:normal, []]}}}} ->
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
          start_attempted: attempted,
          rejection_event: rejection,
          supervisor: is_pid(Process.whereis(Audi.Supervisor)),
          proof_registry: is_pid(Process.whereis(Audi.SSH.Proofs)),
          status_socket: File.exists?(System.fetch_env!("OVERALLS_PROBE_STATUS"))
        })
    )
  end

  @spec observe_rejection(map(), pid()) :: :ignore
  def observe_rejection(%{meta: %{event: "audi.startup_configuration_rejected"}}, tracer) do
    send(tracer, :rejection_event)
    :ignore
  end

  def observe_rejection(_, _), do: :ignore

  @spec trace_loop(boolean(), boolean()) :: :ok
  defp trace_loop(attempted, rejection) do
    receive do
      {:trace, _pid, :call, {Supervisor, :start_link, [_children, options]}} ->
        trace_loop(attempted or Keyword.get(options, :name) == Audi.Supervisor, rejection)

      {:trace, _pid, :call, {module, :start_link, [_options]}} when module in @listeners ->
        trace_loop(true, rejection)

      :rejection_event ->
        trace_loop(attempted, true)

      {:finish, caller, reference} ->
        send(caller, {reference, attempted, rejection})
        :ok

      _ ->
        trace_loop(attempted, rejection)
    end
  end
end

Audi.InvalidBootProbe.run()
