defmodule Lilly.Host.Ownership do
  @moduledoc "One executable Lilly owner per physical host, independent of caller-selected state paths."
  require Lilly.Events
  alias Lilly.Control.Config
  alias Lilly.Host.{Command, Identity, Inventory, Lock, PrivateFiles, UIDReservation}
  @runtime "/run/lilly"
  @persistent "/var/lib/lilly"

  # @cc [owner:ghuntley,label:security;recovery] global-owner-before-execution
  # acquire/1 MUST establish root/systemd/KVM readiness, the enrolled machine identity and fixed
  # /run/lilly ownership before enabling execution. A different configured state directory must
  # not bypass an existing physical-host owner or persistent host binding.

  # @cc [owner:ghuntley,label:security;observability] ownership-events-closed
  # Acquisition events MUST carry no payload; unconfirmed acquisition MUST carry
  # only the closed reason atom. Machine identity documents, state paths and
  # native output MUST NOT be logged.
  @spec acquire(Config.t()) :: {:ok, Lilly.Host.Lease.t()} | {:error, atom()}
  def acquire(%{execution: execution} = config) when not is_nil(execution) do
    with {:ok, %File.Stat{uid: 0}} <- Lilly.Host.Privilege.stat("/proc/self"),
         {:ok, "systemd\n"} <- File.read("/proc/1/comm"),
         {:ok, machine} <- Identity.read(),
         true <- machine == config.client.machine_id,
         true <- config.cgroup_path == "/sys/fs/cgroup/lilly.slice",
         :ok <- UIDReservation.check(),
         {:ok, %{architecture: "x86_64"}} <- Inventory.read(),
         # Queue for the owner lease: a restarted component must not lose to the
         # asynchronous release of its dead predecessor (ADR-0176 decision 4).
         {:ok, port} <- Lock.await(@runtime, 10_000) do
      case initialize(config, machine) do
        :ok ->
          Lilly.Events.emit("lilly.ownership_acquired", [])
          {:ok, port}

        {:error, reason} ->
          Lock.release(port)
          unconfirmed(reason)
          {:error, reason}
      end
    else
      {:error, reason} when is_atom(reason) ->
        unconfirmed(reason)
        {:error, reason}

      _ ->
        unconfirmed(:host_execution_unavailable)
        {:error, :host_execution_unavailable}
    end
  end

  def acquire(_), do: {:error, :host_execution_unavailable}

  defp unconfirmed(reason) do
    Lilly.Events.emit("lilly.ownership_unconfirmed", reason: reason)
    :ok
  end

  defp initialize(config, machine) do
    with {:ok, "active\n"} <-
           Command.run(:systemctl, ["show", "lilly.slice", "--property=ActiveState", "--value"]),
         {:ok, ""} <- Command.run(:kvm_probe, []),
         :ok <- PrivateFiles.directory(@persistent),
         :ok <- bind(config, machine),
         :ok <- PrivateFiles.directory(config.execution.state_dir),
         :ok <- Lilly.Network.setup(config.execution.network),
         do: :ok,
         else: (
           {:error, reason} when is_atom(reason) -> {:error, reason}
           _ -> {:error, :host_execution_unavailable}
         )
  end

  # @cc [owner:ghuntley,label:recovery] unknown-host-resources-fence-readiness
  # verify_units/1 MUST reject any lilly-vm service or lilly.slice child cgroup that lacks a
  # durable command identity; an unsuccessful scan must not establish execution readiness.
  # The unit query MUST request IDs only; verbose unit descriptions must not consume
  # the bounded command-output frame and fence an otherwise tracked fleet.
  @spec verify_units([OverallsProtocol.Execution.command()]) ::
          :ok | {:error, :untracked_vm_units}
  def verify_units(commands) do
    expected = MapSet.new(commands, &("lilly-vm-" <> &1.placement_id <> ".service"))

    with {:ok, body} <-
           Command.run(:systemctl, [
             "show",
             "--property=Id",
             "--value",
             "--no-pager",
             "lilly-vm-*.service"
           ]),
         units = body |> String.split("\n", trim: true) |> Enum.map(&(String.split(&1) |> hd())),
         {:ok, entries} <- File.ls("/sys/fs/cgroup/lilly.slice"),
         groups = Enum.filter(entries, &File.dir?(Path.join("/sys/fs/cgroup/lilly.slice", &1))),
         true <- Enum.all?(units ++ groups, &MapSet.member?(expected, &1)),
         do: :ok,
         else: (_ -> {:error, :untracked_vm_units})
  end

  defp bind(config, machine) do
    expected = %{
      "version" => 1,
      "machine_id" => machine,
      "host_id" => config.client.host_id,
      "state_dir" => config.state_dir,
      "vm_state_dir" => config.execution.state_dir,
      "network_state_dir" => config.execution.network.state_dir,
      "pools" =>
        config.pools
        |> Enum.map(fn pool ->
          Lilly.Host.Pool.session_identity(pool) |> Map.put("path", pool.path)
        end)
        |> Enum.sort_by(& &1["id"])
    }

    path = Path.join(@persistent, "owner.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        PrivateFiles.write(@persistent, "owner.json", JSON.encode!(expected))

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(path),
             {:ok, ^expected} <- JSON.decode(bytes),
             do: :ok,
             else: (_ -> {:error, :host_identity_mismatch})

      _ ->
        {:error, :host_identity_mismatch}
    end
  end
end
