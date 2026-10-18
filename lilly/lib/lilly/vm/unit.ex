defmodule Lilly.VM.Unit do
  @moduledoc "Systemd owns the entire detached boot-log/VMM process tree, independently of Lilly."
  require Lilly.Events
  alias Lilly.Host.{Command, Pool}
  alias Lilly.VM.{Config, Intent, Spec, WorkloadBundle}

  @spec name(Spec.t()) :: String.t()
  def name(spec), do: "lilly-vm-#{spec.id}.service"
  @spec cgroup(Spec.t()) :: Path.t()
  def cgroup(spec), do: "/sys/fs/cgroup/lilly.slice/" <> name(spec)
  @spec boot_log(Config.t(), Spec.t()) :: Path.t()
  def boot_log(config, spec), do: Path.join([config.state_dir, spec.id, "boot.log"])

  @spec start(
          Config.t(),
          Pool.t(),
          Spec.t(),
          Intent.t(),
          WorkloadBundle.t(),
          OverallsProtocol.uuid() | nil
        ) ::
          :ok | {:error, atom()}
  def start(config, pool, spec, intent, bundle, vm_id \\ nil) do
    with {:ok, "active\n"} <-
           Command.run(:systemctl, ["show", "lilly.slice", "--property=ActiveState", "--value"]),
         {:ok, _} <- Command.launch_vm(launch(config, pool, spec, intent, bundle)) do
      unit_started(vm_id, intent)
    end
  end

  @spec restore(Config.t(), Pool.t(), Spec.t(), Intent.t(), WorkloadBundle.t()) ::
          :ok | {:error, atom()}
  def restore(config, pool, spec, intent, bundle) do
    with {:ok, "active\n"} <-
           Command.run(:systemctl, ["show", "lilly.slice", "--property=ActiveState", "--value"]),
         {:ok, _} <-
           Command.launch_vm(Map.put(launch(config, pool, spec, intent, bundle), :restore, true)),
         do: :ok
  end

  defp unit_started(nil, _intent), do: :ok

  defp unit_started(vm_id, intent) do
    Lilly.Events.emit("lilly.unit_started",
      vm_id: vm_id,
      placement_id: intent.placement_id,
      generation: intent.generation
    )

    :ok
  end

  # @cc [owner:ghuntley,label:isolation] independent-confined-service-tree
  # arguments/4 MUST place the boot log and VMM in the VM-owned lilly.slice service tree with
  # control-group kill semantics, PID/network isolation, the native generation guard before
  # jailer, guest-plus-VMM memory limit and swap disabled.
  # The waiting launcher MUST NOT retain a private copy of other VMs' mounts;
  # deleting one stopped VM must not require stopping unrelated running VMs.
  # The unit description MUST bind the launched placement/epoch/generation for
  # independent metrics attribution; it MUST NOT contain guest data or secrets.
  # Firecracker stdio MUST pass through the bounded byte-oriented boot-log
  # writer: kernel console output is a read-only diagnostic and terminals MUST
  # NOT ride the serial console.

  # @cc [owner:ghuntley,label:security] vm-launch-fields-only
  # launch/5 MUST describe the unit only by typed fields (placement, epoch,
  # generation, jail uid, memory, vCPUs, boot kind, restore flag, logging, VM state
  # directory, network namespace and pool root). The command line, including the forking log
  # writer outside the PID namespace and the guarded jailer/Firecracker exec
  # chain as PID 1 inside it, is built by lilly-hostd
  # (vm-launch-argv-derived-by-hostd); Lilly never names an executable.
  @spec launch(Config.t(), Pool.t(), Spec.t(), Intent.t(), WorkloadBundle.t()) ::
          Lilly.Host.Hostd.launch()
  def launch(config, pool, spec, intent, bundle) do
    %{
      placement: spec.id,
      epoch: intent.execution_epoch,
      generation: intent.generation,
      uid: spec.network.uid,
      memory_bytes: Spec.host_memory(spec),
      vcpus: spec.vcpu,
      firmware: bundle.boot_kind == :firmware,
      restore: false,
      logging: config.firecracker_logging,
      state_dir: config.state_dir,
      namespace: config.network.namespace,
      pool: pool.path
    }
  end

  # @cc [owner:ghuntley,label:security;recovery] live-restore-retains-launched-revision
  # launched?/2 MUST match systemd's immutable launch description to the exact
  # current placement/epoch/generation. Current intent or a reusable unit name
  # alone MUST NOT identify the process launched by a consumed restore attempt.
  @spec launched?(Spec.t(), Intent.t()) :: boolean()
  def launched?(spec, intent) do
    expected =
      "Overalls VM v1 placement=#{spec.id} epoch=#{intent.execution_epoch} generation=#{intent.generation}\n"

    intent.placement_id == spec.id and
      Command.run(:systemctl, ["show", name(spec), "--property=Description", "--value"]) ==
        {:ok, expected}
  end

  # @cc [owner:ghuntley,label:recovery;observability] unit-stop-unconfirmed-closed
  # Unconfirmed unit stops MUST report only the VM/placement identifiers and the
  # closed local reason atom; unit names, systemctl output and paths MUST NOT
  # enter diagnostics and the original error result MUST be preserved.
  @spec stop(Spec.t(), OverallsProtocol.uuid() | nil) :: :ok | {:error, atom()}
  def stop(spec, vm_id \\ nil) do
    case stop_result(spec) do
      :ok = ok ->
        ok

      {:error, reason} ->
        stop_unconfirmed(spec, vm_id, reason)
    end
  end

  @doc "Force-terminate a paused service after its checkpoint is durably sealed."
  @spec kill_paused(Spec.t()) :: :ok | {:error, atom()}
  def kill_paused(spec) do
    case Command.run(:systemctl, ["kill", "--kill-who=all", "--signal=KILL", name(spec)], 5000) do
      {:ok, _} -> await_stopped(spec, System.monotonic_time(:millisecond) + 5000)
      error -> error
    end
  end

  defp stop_result(spec) do
    case status(spec) do
      {:ok, :stopped} ->
        :ok

      {:ok, :running} ->
        with {:ok, _} <- Command.run(:systemctl, ["stop", name(spec)], 15_000),
             :ok <- await_stopped(spec, System.monotonic_time(:millisecond) + 5000),
             do: :ok

      error ->
        error
    end
  end

  defp stop_unconfirmed(_spec, nil, reason), do: {:error, reason}

  defp stop_unconfirmed(spec, vm_id, reason) do
    Lilly.Events.emit("lilly.unit_stop_unconfirmed",
      vm_id: vm_id,
      placement_id: spec.id,
      reason: reason
    )

    {:error, reason}
  end

  defp await_stopped(spec, deadline) do
    case status(spec) do
      {:ok, :stopped} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :stop_unconfirmed}
        else
          receive do
          after
            50 -> await_stopped(spec, deadline)
          end
        end
    end
  end

  # @cc [owner:ghuntley,label:recovery] empty-unit-proof-not-command-failure
  # status/1 MUST report stopped only with a proven empty or absent VM cgroup and an
  # inactive/failed unit or a successful absent-unit scan. A failed systemctl request by itself
  # must never prove a state. An inconclusive observation (systemctl unavailable or timed out,
  # a transitional ActiveState, unreadable cgroup.events) MUST be :unit_state_unavailable, which
  # callers retry; only a contradictory observation (e.g. inactive with a populated cgroup, or
  # active in the wrong cgroup) is :unit_state_unknown. Slowness is never evidence (ADR-0140).
  @spec status(Spec.t()) ::
          {:ok, :running | :stopped} | {:error, :unit_state_unknown | :unit_state_unavailable}
  def status(spec) do
    with {:ok, body} <-
           Command.run(:systemctl, [
             "show",
             name(spec),
             "--property=ActiveState",
             "--property=ControlGroup"
           ]),
         fields =
           body
           |> String.split("\n", trim: true)
           |> Map.new(fn line ->
             [k, v] = String.split(line, "=", parts: 2)
             {k, v}
           end) do
      classify(fields["ActiveState"], fields["ControlGroup"], populated(spec), spec.id)
    else
      {:error, :command_failed} -> missing_unit_status(spec)
      _ -> {:error, :unit_state_unavailable}
    end
  end

  @transitional ["activating", "deactivating", "reloading", "refreshing"]

  @doc false
  @spec classify(String.t() | nil, String.t() | nil, boolean() | :unknown, String.t()) ::
          {:ok, :running | :stopped} | {:error, :unit_state_unknown | :unit_state_unavailable}
  def classify("active", group, true, id)
      when group == "/lilly.slice/" <> "lilly-vm-" <> id <> ".service",
      do: {:ok, :running}

  def classify(state, _group, false, _id) when state in ["inactive", "failed"],
    do: {:ok, :stopped}

  def classify(state, _group, _populated, _id) when state in @transitional,
    do: {:error, :unit_state_unavailable}

  def classify(_state, _group, :unknown, _id), do: {:error, :unit_state_unavailable}
  def classify(_state, _group, _populated, _id), do: {:error, :unit_state_unknown}

  defp missing_unit_status(spec) do
    # --collect removes a finished transient unit. `show` then exits nonzero;
    # prove absence through a successful list operation and an empty cgroup.
    with {:ok, body} <-
           Command.run(
             :systemctl,
             ["list-units", "--all", "--plain", "--no-legend", "--no-pager", name(spec)]
           ),
         true <- String.trim(body) == "",
         false <- populated(spec),
         do: {:ok, :stopped},
         else: (
           true -> {:error, :unit_state_unknown}
           _ -> {:error, :unit_state_unavailable}
         )
  end

  defp populated(spec) do
    case File.read(Path.join(cgroup(spec), "cgroup.events")) do
      {:ok, body} ->
        cond do
          "populated 0" in String.split(body, "\n") -> false
          "populated 1" in String.split(body, "\n") -> true
          true -> :unknown
        end

      {:error, :enoent} ->
        false

      _ ->
        :unknown
    end
  end
end
