defmodule Porsche.HostCertificateBootProbe do
  @moduledoc false
  @entries [
    {Supervisor, :start_link, 2},
    {Porsche.Listener, :start_link, 1},
    {Porsche.StatusServer, :start_link, 1},
    {Porsche.Observability, :start_link, 1},
    {:ssh, :daemon, 3}
  ]
  @base_names [
    Porsche.SSH.Proofs,
    Porsche.SSH.Sessions,
    Porsche.SSH.Connections,
    Porsche.SSH.Commands,
    Porsche.Watchers,
    Porsche.Terminal.Attachments,
    Porsche.Observability
  ]
  @type flags :: %{
          supervisor_attempted: boolean(),
          listener_attempted: boolean(),
          status_attempted: boolean(),
          observability_attempted: boolean(),
          daemon_attempted: boolean()
        }

  # @cc [owner:ghuntley,label:security;verification] host-certificate-probe-fixture
  # This fresh-BEAM probe MUST require explicit test opt-in and operate in its
  # private fixture. Startup results and trace arguments MUST leave the process
  # only as closed outcomes and booleans. Only the positive control may remove
  # its owned status socket after stopping the application.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "host-certificate probe requires explicit test opt-in"
    end

    File.cd!(System.fetch_env!("OVERALLS_PROBE_ROOT"))
    Enum.each(@entries, fn {module, _, _} -> Code.ensure_loaded!(module) end)

    flags = %{
      supervisor_attempted: false,
      listener_attempted: false,
      status_attempted: false,
      observability_attempted: false,
      daemon_attempted: false
    }

    tracer = spawn_link(fn -> trace_loop(flags) end)
    Enum.each(@entries, fn entry -> 1 = :erlang.trace_pattern(entry, true, [:local]) end)
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])
    result = Application.ensure_all_started(:porsche)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "host-certificate trace delivery timed out"
    end

    reference = make_ref()
    send(tracer, {:finish, self(), reference})

    observed =
      receive do
        {^reference, observed} -> observed
      after
        5_000 -> raise "host-certificate trace collection timed out"
      end

    :erlang.trace(:all, false, [:all])

    outcome =
      case result do
        {:error,
         {:porsche,
          {{:shutdown, {:failed_to_start_child, Porsche.Listener, :invalid_configuration}},
           {Porsche.Application, :start, [:normal, []]}}}} ->
          "rejected"

        {:ok, _} ->
          "started"

        _ ->
          "other"
      end

    supervisor = Process.whereis(Porsche.Supervisor)
    listener = Process.whereis(Porsche.Listener)
    socket = System.fetch_env!("OVERALLS_PROBE_SOCKET")
    ready = is_pid(listener) and Porsche.Listener.ready?(listener)

    projection =
      Map.merge(observed, %{
        outcome: outcome,
        supervisor: is_pid(supervisor),
        base_present: Enum.any?(@base_names, &is_pid(Process.whereis(&1))),
        configured_children: configured_children?(supervisor),
        listener: is_pid(listener),
        socket: File.exists?(socket),
        ready: ready,
        ssh_banner: ready and ssh_banner?(listener)
      })

    if System.get_env("OVERALLS_PROBE_MODE") == "positive" and outcome == "started" do
      :ok = Application.stop(:porsche)
      :ok = File.rm(socket)
    end

    IO.puts("CERT_BOOT_PROBE:" <> JSON.encode!(projection))
    :ok
  end

  @spec configured_children?(pid() | nil) :: boolean()
  defp configured_children?(supervisor) when is_pid(supervisor) do
    children = Supervisor.which_children(supervisor)
    names = @base_names ++ [Porsche.Listener]
    pids = Enum.map(children, fn {_, pid, _, _} -> pid end)

    length(children) == 10 and
      Enum.all?(names, fn name ->
        pid = Process.whereis(name)
        is_pid(pid) and pid in pids
      end) and
      Enum.any?(children, fn {id, pid, _, _} -> id == Porsche.StatusServer and is_pid(pid) end) and
      Enum.any?(children, fn {id, pid, _, _} -> id == Porsche.Control.Link and is_pid(pid) end)
  end

  defp configured_children?(_), do: false

  @spec ssh_banner?(pid()) :: boolean()
  defp ssh_banner?(listener) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             Porsche.Listener.port(listener),
             [:binary, active: false],
             2000
           ) do
      result = match?({:ok, "SSH-2.0-" <> _}, :gen_tcp.recv(socket, 0, 2000))
      :ok = :gen_tcp.close(socket)
      result
    else
      _ -> false
    end
  end

  @spec trace_loop(flags()) :: :ok
  defp trace_loop(flags) do
    receive do
      {:trace, _, :call, {Supervisor, :start_link, [_, options]}} ->
        attempted =
          flags.supervisor_attempted or Keyword.get(options, :name) == Porsche.Supervisor

        trace_loop(%{flags | supervisor_attempted: attempted})

      {:trace, _, :call, {:ssh, :daemon, [_, _, _]}} ->
        trace_loop(%{flags | daemon_attempted: true})

      {:trace, _, :call, {module, :start_link, [_]}}
      when module in [Porsche.Listener, Porsche.StatusServer, Porsche.Observability] ->
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

Porsche.HostCertificateBootProbe.run()
