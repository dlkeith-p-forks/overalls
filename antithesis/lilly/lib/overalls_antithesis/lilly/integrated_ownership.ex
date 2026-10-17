defmodule OverallsAntithesis.Lilly.IntegratedOwnership do
  @moduledoc "Exclusive inner-host owner for real ZFS and emulated guest execution."

  require Lilly.Events
  alias OverallsAntithesis.Lilly.GuestExecutor
  alias Lilly.Control.Config
  alias Lilly.Host.{Command, Identity, Inventory, Lock, PrivateFiles, UIDReservation}
  @runtime "/run/lilly"
  @persistent "/var/lib/lilly"

  # @cc [owner:ghuntley,label:security;recovery] integrated-owner-is-host-bound
  # Acquisition MUST retain root, systemd, machine-ID, reserved-UID,
  # fixed-lock and durable host/pool binding gates. Only the native
  # KVM probe is omitted because this selected inner host runs QEMU TCG.
  # An existing native owner binding MUST NOT be adopted as an emulated owner.
  @spec acquire(Config.t()) :: {:ok, port()} | {:error, atom()}
  def acquire(%{execution: execution} = config) when not is_nil(execution) do
    with {:ok, %File.Stat{uid: 0}} <- File.stat("/proc/self"),
         {:ok, "systemd\n"} <- File.read("/proc/1/comm"),
         {:ok, machine} <- Identity.read(),
         true <- machine == config.client.machine_id,
         true <- config.cgroup_path == "/sys/fs/cgroup/lilly.slice",
         true <- config.pools != [] and Enum.all?(config.pools, &(&1.backend == :zfs)),
         :ok <- UIDReservation.check(),
         {:ok, %{architecture: "x86_64"}} <- Inventory.read(),
         {:ok, port} <- Lock.acquire(@runtime) do
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

  @spec initialize(Config.t(), String.t()) :: :ok | {:error, atom()}
  defp initialize(config, machine) do
    with {:ok, "active\n"} <-
           Command.run(:systemctl, ["show", "lilly.slice", "--property=ActiveState", "--value"]),
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

  @spec bind(Config.t(), String.t()) :: :ok | {:error, atom()}
  defp bind(config, machine) do
    expected = %{
      "version" => 1,
      "backend" => "antithesis-tcg-v1",
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

  @spec unconfirmed(atom()) :: :ok
  defp unconfirmed(reason) do
    Lilly.Events.emit("lilly.ownership_unconfirmed", reason: reason)
    :ok
  end

  # @cc [owner:ghuntley,label:recovery] integrated-owner-checks-both-process-trees
  # The integrated host MUST validate both native unit/cgroup inventory and
  # guest-vmm's complete emulator inventory before restoring actors.
  @spec verify_units([OverallsProtocol.Execution.command()]) ::
          :ok | {:error, :untracked_vm_units}
  def verify_units(commands) do
    with :ok <- verify_fixed_native_units(commands),
         :ok <- GuestExecutor.verify_units(commands),
         do: :ok
  end

  # @cc [owner:ghuntley,label:security;recovery] integrated-fixed-unit-boundary
  # The TCG host may retain its fixed lilly.service and lilly-guest-emulator.service
  # cgroups while no guest VM is tracked. Exact expected lilly-vm units may join
  # them when systemd creates them, but QEMU guests may be owned by the shared
  # emulator service, so an expected VM unit may be absent. Unknown units,
  # unknown cgroups, and malformed inventory fence actor recovery. This harness
  # adapter deliberately does not weaken native
  # Lilly.Host.Ownership.verify_units/1.
  @spec verify_fixed_native_units([OverallsProtocol.Execution.command()]) ::
          :ok | {:error, :untracked_vm_units}
  def verify_fixed_native_units(commands) when is_list(commands) do
    with {:ok, expected} <- expected_units(commands),
         {:ok, body} <-
           Command.run(:systemctl, [
             "show",
             "--property=Id",
             "--value",
             "--no-pager",
             "lilly-vm-*.service"
           ]),
         {:ok, units} <- parse_units(body),
         {:ok, groups} <- File.ls("/sys/fs/cgroup/lilly.slice"),
         groups <- Enum.filter(groups, &File.dir?(Path.join("/sys/fs/cgroup/lilly.slice", &1))),
         true <- fixed_native_inventory?(units, groups, expected) do
      :ok
    else
      _ -> {:error, :untracked_vm_units}
    end
  end

  def verify_fixed_native_units(_), do: {:error, :untracked_vm_units}

  @spec expected_units([OverallsProtocol.Execution.command()]) ::
          {:ok, MapSet.t(String.t())} | :error
  defp expected_units(commands) do
    ids = Enum.map(commands, &Map.get(&1, :placement_id))

    if Enum.all?(ids, &OverallsProtocol.uuid?/1) and length(ids) == length(Enum.uniq(ids)) do
      {:ok, MapSet.new(ids, &("lilly-vm-" <> &1 <> ".service"))}
    else
      :error
    end
  end

  @spec fixed_native_inventory?([String.t()], [String.t()], MapSet.t(String.t())) :: boolean()
  def fixed_native_inventory?(units, groups, expected)
      when is_list(units) and is_list(groups) do
    observed = MapSet.new(units ++ groups)

    allowed =
      MapSet.union(expected, MapSet.new(["lilly.service", "lilly-guest-emulator.service"]))

    Enum.all?(observed, &MapSet.member?(allowed, &1))
  end

  @spec parse_units(term()) :: {:ok, [String.t()]} | :error
  def parse_units(body) when is_binary(body) and byte_size(body) <= 65_536 do
    if String.valid?(body) do
      units =
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      if Enum.all?(units, &valid_unit?/1), do: {:ok, units}, else: :error
    else
      :error
    end
  end

  def parse_units(_), do: :error

  @spec valid_unit?(String.t()) :: boolean()
  defp valid_unit?(unit),
    do:
      byte_size(unit) in 1..256 and
        not String.contains?(unit, [<<0>>, "\r", "/", "\\"])
end
