defmodule Audi.Health do
  @moduledoc "Point-in-time role readiness for private deployment health checks."

  # @cc [owner:ghuntley,label:security;recovery] audi-health-live-authority
  # Readiness MUST require live managed listeners before and after a bounded
  # authenticated control request. DNS additionally requires a fresh replica;
  # gateways require their current catalog (including registered host identity).
  # Only a positive result within five seconds may succeed. Health MUST NOT
  # create sessions, extend authority, issue certificates or expose diagnostics.
  # Version-fenced automatic workers MUST withhold readiness even if control
  # transport recovers before an operator restarts the local owner.
  @spec ready?(Audi.Control.Client.t(), :dns | :gateway, list(), keyword()) :: boolean()
  def ready?(client, role, ports \\ [], options \\ []) do
    started = System.monotonic_time(:millisecond)
    listeners = Keyword.get(options, :listeners, &managed?/1)
    control = Keyword.get(options, :control, &control/2)
    directory = Keyword.get(options, :directory, Audi.DNS.Directory)

    client.role == role and role in [:dns, :gateway] and listeners.(role) == true and
      Enum.all?(ports, &port?/1) and match?({:ok, _}, control.(client, role)) and
      (role == :gateway or match?({:ok, _, _}, Audi.DNS.Directory.lookup(directory, ""))) and
      listeners.(role) == true and Enum.all?(ports, &port?/1) and
      System.monotonic_time(:millisecond) - started < 5000
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp control(client, :dns), do: Audi.Control.Client.identity(client)
  defp control(client, :gateway), do: Audi.Control.Client.gateway_catalog(client)

  defp managed?(role) do
    children = Supervisor.which_children(Audi.Supervisor)

    live? =
      Enum.all?(children, fn
        {worker, pid, _, _}
        when worker in [Audi.DNS.Replica, Audi.SSH.KeyPublisher, Audi.TLS.FleetWorker] ->
          is_pid(pid) and Process.alive?(pid) and worker.automatic_work_enabled?(pid)

        {_, pid, _, _} ->
          is_pid(pid) and Process.alive?(pid)
      end)

    name = if role == :dns, do: Audi.DNS.Server, else: Audi.SSH.Listener

    case List.keyfind(children, name, 0) do
      {^name, pid, _, _} when is_pid(pid) -> live? and name.ready?(pid)
      _ -> false
    end
  end

  defp port?({address, port}) do
    case :gen_tcp.connect(address, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
