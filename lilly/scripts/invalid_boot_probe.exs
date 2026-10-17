defmodule Lilly.InvalidBootProbe do
  @moduledoc false

  @message "invalid LILLY_CONFIG_FILE; expected a private, valid provisioner configuration"

  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "boot probe requires the explicit test environment"
    end

    targets = [Supervisor, Lilly.Control.Runtime, Lilly.Control.StatusServer]
    Enum.each(targets, &Code.ensure_loaded!/1)
    tracer = spawn_link(fn -> trace_loop(false) end)

    for module <- targets do
      arity = if module == Supervisor, do: 2, else: 1
      :erlang.trace_pattern({module, :start_link, arity}, true, [:local])
    end

    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])
    result = Application.ensure_all_started(:lilly)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "boot trace delivery timed out"
    end

    reference = make_ref()
    send(tracer, {:finish, self(), reference})

    attempted =
      receive do
        {^reference, attempted} when is_boolean(attempted) -> attempted
      after
        5_000 -> raise "boot trace collection timed out"
      end

    :erlang.trace(:all, false, [:all])

    outcome =
      case result do
        {:error,
         {:lilly,
          {:bad_return,
           {{Lilly.Application, :start, [:normal, []]},
            {:EXIT, {%RuntimeError{message: @message}, _stack}}}}}} ->
          "rejected"

        {:ok, _applications} ->
          "started"

        _ ->
          "other"
      end

    projection = %{
      outcome: outcome,
      child_start_attempted: attempted,
      supervisor: is_pid(Process.whereis(Lilly.Supervisor)),
      runtime: is_pid(Process.whereis(Lilly.Control.Runtime)),
      status_socket: File.exists?(System.fetch_env!("LILLY_STATUS_SOCKET")),
      terminal_socket:
        File.exists?(
          Path.join(
            Path.dirname(System.fetch_env!("LILLY_STATUS_SOCKET")),
            "terminal-metrics.sock"
          )
        )
    }

    IO.puts("BOOT_PROBE:" <> JSON.encode!(projection))
  end

  @spec trace_loop(boolean()) :: :ok
  defp trace_loop(attempted) do
    receive do
      {:trace, _pid, :call, {Supervisor, :start_link, [_children, options]}} ->
        trace_loop(attempted or Keyword.get(options, :name) == Lilly.Supervisor)

      {:trace, _pid, :call, {module, :start_link, [_options]}}
      when module in [Lilly.Control.Runtime, Lilly.Control.StatusServer] ->
        trace_loop(true)

      {:finish, caller, reference} ->
        send(caller, {reference, attempted})
        :ok

      _ ->
        trace_loop(attempted)
    end
  end
end

Lilly.InvalidBootProbe.run()
