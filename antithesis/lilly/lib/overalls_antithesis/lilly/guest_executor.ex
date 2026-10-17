defmodule OverallsAntithesis.Lilly.GuestExecutor do
  @moduledoc "Emulated guest execution through the independently owned QEMU TCG runner."
  @behaviour Lilly.VM.Executor

  alias OverallsAntithesis.Lilly.{GuestBoot, GuestChannels, GuestRPC, GuestTrustReceipt}
  alias OverallsProtocol.{Execution, ImageManifest}
  alias Lilly.Control.Config
  alias Lilly.VM.GuestTrust
  alias Lilly.VM.Executor

  @memory_bytes 2_147_483_648
  @maximum 9_223_372_036_854_775_807
  @pool_backend if(System.get_env("ANTITHESIS_INTEGRATED_HOST") == "1",
                  do: :zfs,
                  else: :controlled
                )
  @observation_keys ~w(state placement_id execution_epoch generation boot_id qemu_pid backend_pid ready qemu_rss_kib backend_rss_kib error)
  @inventory_keys ~w(placement_id execution_epoch generation state live overlay_present qemu_pid backend_pid)
  @proof_keys ~w(state placement_id execution_epoch generation qemu_pid qemu_start_ticks backend_pid backend_start_ticks)

  @type runner_state :: :running | :stopped | :degraded | :uncertain
  @type runner_observation :: %{
          state: runner_state(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          boot_id: String.t() | nil,
          qemu_pid: pos_integer() | nil,
          backend_pid: pos_integer() | nil,
          ready: boolean(),
          qemu_rss_kib: non_neg_integer() | nil,
          backend_rss_kib: non_neg_integer() | nil
        }

  # @cc [owner:ghuntley,label:security;verification] guest-outcomes-require-emulated-proof
  # Running requires exact immutable emulator image and shape, a durable local
  # challenge, owned live QEMU/backend identities and current port-1024 guest
  # readiness. Stop requires confirmed exit and retained overlay inventory.
  # Native Firecracker, ZFS, terminal, ingress and delete effects MUST NOT be
  # inferred from an emulator observation.
  @impl true
  @spec reconcile(Config.t(), Execution.command(), map()) :: Executor.result()
  def reconcile(config, command, history) do
    with {:ok, _spec} <- Executor.specification(command),
         true <- owned_pool?(config, command),
         :ok <- image_and_shape(command) do
      case command.kind do
        kind when kind in [:provision, :start] -> start_or_crash(config, command, history)
        :stop -> stop(config, command)
        :delete -> retire_compute(config, command)
        _ -> {:retry, :execution_unavailable}
      end
    else
      _ -> {:retry, :execution_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery;verification] emulated-crash-needs-exit-and-cleanup
  # A running command MUST become failed/crashed only after the exact recorded
  # QEMU exit is positively proven, the surviving backend is stopped, the
  # retained overlay is verified, and durable actor history proves that same
  # epoch/generation ran. Unknown proof MUST NOT become a crash outcome.
  @spec start_or_crash(Config.t(), Execution.command(), map()) :: Executor.result()
  defp start_or_crash(config, command, history) do
    case GuestBoot.read(config.state_dir, command.placement_id) do
      {:ok, %{state: :running} = boot} ->
        if same_boot?(boot, command) do
          case process_proof(boot) do
            {:ok, %{state: :qemu_exited}} ->
              case stop(config, command) do
                {:ok, stopped} ->
                  reason =
                    if Map.get(history, :running_epoch) == command.execution_epoch and
                         Map.get(history, :running_generation) == command.generation,
                       do: :crashed,
                       else: :execution_failed

                  {:ok, %{stopped | state: :failed, reason: reason}}

                _ ->
                  {:retry, :execution_unavailable}
              end

            _ ->
              start(config, command)
          end
        else
          start(config, command)
        end

      _ ->
        start(config, command)
    end
  end

  @spec same_boot?(GuestBoot.t(), Execution.command()) :: boolean()
  defp same_boot?(boot, command),
    do:
      boot.placement_id == command.placement_id and
        boot.execution_epoch == command.execution_epoch and
        boot.generation == command.generation and boot.image_id == command.image_id and
        boot.disk_bytes == command.disk_bytes and boot.profile == command.profile and
        boot.slot == command.slot

  @spec start(Config.t(), Execution.command()) :: Executor.result()
  defp start(config, command) do
    with :ok <- private_launch_ready(config, command),
         {:ok, boot} <- GuestBoot.prepare(config.state_dir, command),
         {:ok, launched} <- guest_call("reconcile", boot),
         true <-
           launched.state == :running and is_integer(launched.qemu_pid) and
             is_integer(launched.backend_pid),
         {:ok, trust_boot_id} <- maybe_deliver_trust(config, boot, launched),
         {:ok, ready} <- await_readiness(boot, trust_boot_id),
         true <- ready.state == :running and ready.ready,
         true <- ready.qemu_pid == launched.qemu_pid and ready.backend_pid == launched.backend_pid,
         true <- is_nil(trust_boot_id) or ready.boot_id == trust_boot_id,
         :ok <- GuestBoot.mark(config.state_dir, boot, :running) do
      {:ok, running_facts()}
    else
      _ -> {:retry, :execution_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] private-services-before-guest-effect
  # A private guest launch or restart MUST refuse before the runner reconcile
  # effect unless Ziggy and Audi are currently ready. An exact pinned live boot
  # may be re-observed without that check; missing or uncertain process proof
  # MUST NOT grant the running-boot exception.
  @spec private_launch_ready(Config.t(), Execution.command()) ::
          :ok | {:error, :execution_unavailable}
  defp private_launch_ready(
         %{execution: %{network: %Lilly.Network.Config{private_services: false}}},
         _command
       ),
       do: :ok

  defp private_launch_ready(
         %{execution: %{network: %Lilly.Network.Config{private_services: true} = network}} =
           config,
         command
       ) do
    case GuestBoot.read(config.state_dir, command.placement_id) do
      {:ok, %{state: state} = boot} when state in [:launching, :running] ->
        if same_boot?(boot, command) and
             match?({:ok, %{state: :running}}, process_proof(boot)),
           do: :ok,
           else: require_private_readiness(network)

      {:ok, _} ->
        require_private_readiness(network)

      _ ->
        {:error, :execution_unavailable}
    end
  end

  defp private_launch_ready(_, _), do: {:error, :execution_unavailable}

  @spec require_private_readiness(Lilly.Network.Config.t()) ::
          :ok | {:error, :execution_unavailable}
  defp require_private_readiness(network) do
    if Lilly.Private.Readiness.ready?(network),
      do: :ok,
      else: {:error, :execution_unavailable}
  end

  # @cc [owner:ghuntley,label:security;recovery] emulated-trust-before-ready
  # With public roots configured, delivery MUST be bracketed by matching pinned
  # live emulator process and inner-kernel cgroup proofs. The exact boot receipt
  # MUST be durable before port-1024 readiness can establish running. An empty
  # root set does not grant a private terminal channel.
  @spec maybe_deliver_trust(Config.t(), GuestBoot.t(), runner_observation()) ::
          {:ok, OverallsProtocol.uuid() | nil} | {:error, :execution_unavailable}
  defp maybe_deliver_trust(
         %{execution: %{guest_trust_roots: [_ | _] = roots}} = config,
         boot,
         launched
       ) do
    with {:ok, %{state: :running} = before} <- process_proof(boot),
         true <-
           before.qemu_pid == launched.qemu_pid and
             before.backend_pid == launched.backend_pid,
         {:ok, _target} <- local_watch_target(before),
         {:ok, path} <- GuestChannels.socket_path(boot),
         {:ok, boot_id, digest, fresh?} <- trust_receipt_or_delivery(config, boot, roots, path),
         {:ok, ^before} <- process_proof(boot),
         {:ok, _target} <- local_watch_target(before),
         :ok <- persist_trust_receipt(config, boot, roots, boot_id, digest, fresh?) do
      {:ok, boot_id}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  defp maybe_deliver_trust(_config, _boot, _launched), do: {:ok, nil}

  @spec trust_receipt_or_delivery(Config.t(), GuestBoot.t(), [binary()], Path.t()) ::
          {:ok, OverallsProtocol.uuid(), String.t(), boolean()}
          | {:error, :execution_unavailable}
  defp trust_receipt_or_delivery(config, boot, roots, path) do
    case GuestTrustReceipt.read(config.state_dir, boot, roots) do
      {:ok, boot_id} ->
        {:ok, boot_id, GuestTrust.digest(roots), false}

      _ ->
        trust_boot = %{
          placement_id: boot.placement_id,
          execution_epoch: boot.execution_epoch,
          generation: boot.generation,
          boot_challenge: boot.boot_challenge
        }

        case GuestTrust.deliver(path, trust_boot, roots, 120_000) do
          {:ok, boot_id, digest} -> {:ok, boot_id, digest, true}
          _ -> {:error, :execution_unavailable}
        end
    end
  end

  @spec persist_trust_receipt(
          Config.t(),
          GuestBoot.t(),
          [binary()],
          OverallsProtocol.uuid(),
          String.t(),
          boolean()
        ) :: :ok | {:error, :execution_unavailable}
  defp persist_trust_receipt(_config, _boot, _roots, _boot_id, _digest, false), do: :ok

  defp persist_trust_receipt(config, boot, roots, boot_id, digest, true) do
    case GuestTrustReceipt.write(config.state_dir, boot, roots, boot_id, digest) do
      :ok -> :ok
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec await_readiness(GuestBoot.t(), OverallsProtocol.uuid() | nil) ::
          {:ok, runner_observation()} | {:error, :execution_unavailable}
  defp await_readiness(boot, nil), do: guest_call("readiness", boot)

  defp await_readiness(boot, _boot_id) do
    poll_readiness(boot, System.monotonic_time(:millisecond) + 30_000)
  end

  @spec poll_readiness(GuestBoot.t(), integer()) ::
          {:ok, runner_observation()} | {:error, :execution_unavailable}
  defp poll_readiness(boot, deadline) do
    case guest_call("readiness", boot) do
      {:ok, %{state: :running, ready: true} = observed} ->
        {:ok, observed}

      {:ok, %{state: :running, ready: false}} when deadline > 0 ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          poll_readiness(boot, deadline)
        else
          {:error, :execution_unavailable}
        end

      _ ->
        {:error, :execution_unavailable}
    end
  end

  @spec stop(Config.t(), Execution.command()) :: Executor.result()
  defp stop(config, command) do
    with {:ok, boot} <- previous_boot(config, command),
         {:ok, observed} <- guest_call("stop", boot),
         true <- stopped?(observed),
         {:ok, entries} <- inventory(),
         true <- retained_stopped?(entries, boot),
         :ok <- GuestBoot.mark(config.state_dir, boot, :stopped) do
      {:ok, stopped_facts()}
    else
      _ -> {:retry, :execution_unavailable}
    end
  end

  @spec retire_compute(Config.t(), Execution.command()) :: Executor.result()
  defp retire_compute(config, command) do
    _ = stop(config, command)
    {:retry, :execution_unavailable}
  end

  @spec previous_boot(Config.t(), Execution.command()) ::
          {:ok, GuestBoot.t()} | {:error, :guest_boot_unconfirmed}
  defp previous_boot(config, command) do
    with {:ok, %{} = boot} <- GuestBoot.read(config.state_dir, command.placement_id),
         true <- boot.image_id == command.image_id and boot.disk_bytes == command.disk_bytes,
         true <- boot.profile == command.profile and boot.slot == command.slot,
         true <-
           {boot.execution_epoch, boot.generation} <=
             {command.execution_epoch, command.generation} do
      {:ok, boot}
    else
      _ -> {:error, :guest_boot_unconfirmed}
    end
  end

  @spec owned_pool?(Config.t(), Execution.command()) :: boolean()
  defp owned_pool?(config, command) do
    Enum.any?(config.pools, &(&1.id == command.pool_id and &1.backend == @pool_backend))
  end

  @spec image_and_shape(Execution.command()) :: :ok | {:error, :unsupported_guest_shape}
  defp image_and_shape(command) do
    with true <- command.vcpu == 1 and command.memory_bytes == @memory_bytes,
         true <- is_nil(Map.get(command, :workspace_source)),
         true <- is_nil(Map.get(command, :clone_id)) and is_nil(Map.get(command, :resize_id)),
         {:ok,
          %{
            "state" => "ok",
            "image_id" => image_id,
            "minimum_disk_bytes" => minimum,
            "memory_bytes" => @memory_bytes,
            "vcpu" => 1,
            "workspace_source_version" => source_version
          } = identity} <- GuestRPC.call(%{"operation" => "identity"}),
         true <- map_size(identity) == 6 and source_version in [nil, 2],
         true <- ImageManifest.id?(image_id) and image_id == command.image_id,
         true <- is_integer(minimum) and minimum in 2_147_483_648..@maximum,
         true <- command.disk_bytes >= minimum do
      :ok
    else
      _ -> {:error, :unsupported_guest_shape}
    end
  end

  @spec guest_call(String.t(), GuestBoot.t()) ::
          {:ok, runner_observation()} | {:error, :execution_unavailable}
  defp guest_call(operation, boot) do
    with {:ok, raw} <- GuestRPC.call(guest_request(operation, boot)),
         {:ok, observation} <- decode_observation(raw, boot) do
      {:ok, observation}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec guest_request(String.t(), GuestBoot.t()) :: GuestRPC.request()
  defp guest_request(operation, boot) do
    %{
      "operation" => operation,
      "placement_id" => boot.placement_id,
      "execution_epoch" => boot.execution_epoch,
      "generation" => boot.generation,
      "boot_challenge" => boot.boot_challenge,
      "address" => boot.address,
      "tap" => boot.tap,
      "mac" => boot.mac,
      "disk_bytes" => boot.disk_bytes
    }
  end

  @type process_proof :: %{
          state: :running | :qemu_exited,
          qemu_pid: pos_integer(),
          qemu_start_ticks: pos_integer(),
          backend_pid: pos_integer() | nil,
          backend_start_ticks: pos_integer() | nil
        }

  @spec process_proof(GuestBoot.t()) ::
          {:ok, process_proof()} | {:error, :execution_unavailable}
  defp process_proof(boot) do
    with {:ok, raw} <- GuestRPC.call(guest_request("process_proof", boot)),
         true <- Enum.sort(Map.keys(raw)) == Enum.sort(@proof_keys),
         state when state in ["running", "qemu_exited"] <- raw["state"],
         true <- raw["placement_id"] == boot.placement_id,
         true <- raw["execution_epoch"] == boot.execution_epoch,
         true <- raw["generation"] == boot.generation,
         qemu_pid when is_integer(qemu_pid) and qemu_pid in 2..4_194_304 <- raw["qemu_pid"],
         qemu_ticks when is_integer(qemu_ticks) and qemu_ticks > 0 <- raw["qemu_start_ticks"],
         true <- optional_pid?(raw["backend_pid"]),
         true <- optional_tick?(raw["backend_start_ticks"]),
         true <- is_nil(raw["backend_pid"]) == is_nil(raw["backend_start_ticks"]),
         true <- state != "running" or is_integer(raw["backend_pid"]) do
      {:ok,
       %{
         state: if(state == "running", do: :running, else: :qemu_exited),
         qemu_pid: qemu_pid,
         qemu_start_ticks: qemu_ticks,
         backend_pid: raw["backend_pid"],
         backend_start_ticks: raw["backend_start_ticks"]
       }}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec runner_state(String.t()) :: runner_state()
  defp runner_state("running"), do: :running
  defp runner_state("stopped"), do: :stopped
  defp runner_state("degraded"), do: :degraded
  defp runner_state("uncertain"), do: :uncertain

  @spec optional_tick?(term()) :: boolean()
  defp optional_tick?(nil), do: true
  defp optional_tick?(value), do: is_integer(value) and value > 0

  @spec decode_observation(map(), GuestBoot.t()) ::
          {:ok, runner_observation()} | {:error, :execution_unavailable}
  defp decode_observation(raw, boot) do
    with true <- Enum.sort(Map.keys(raw)) == Enum.sort(@observation_keys),
         state when state in ["running", "stopped", "degraded", "uncertain"] <- raw["state"],
         true <- raw["placement_id"] == boot.placement_id,
         true <- raw["execution_epoch"] == boot.execution_epoch,
         true <- raw["generation"] == boot.generation,
         true <- is_boolean(raw["ready"]) and is_nil(raw["error"]),
         true <- optional_pid?(raw["qemu_pid"]) and optional_pid?(raw["backend_pid"]),
         true <-
           optional_nonnegative?(raw["qemu_rss_kib"]) and
             optional_nonnegative?(raw["backend_rss_kib"]),
         true <- valid_boot_id?(raw["boot_id"], raw["ready"]),
         true <-
           not raw["ready"] or
             (state == "running" and is_integer(raw["qemu_pid"]) and
                is_integer(raw["backend_pid"])) do
      {:ok,
       %{
         state: runner_state(state),
         placement_id: boot.placement_id,
         execution_epoch: boot.execution_epoch,
         generation: boot.generation,
         boot_id: raw["boot_id"],
         qemu_pid: raw["qemu_pid"],
         backend_pid: raw["backend_pid"],
         ready: raw["ready"],
         qemu_rss_kib: raw["qemu_rss_kib"],
         backend_rss_kib: raw["backend_rss_kib"]
       }}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec optional_pid?(term()) :: boolean()
  defp optional_pid?(nil), do: true
  defp optional_pid?(value), do: is_integer(value) and value > 1

  @spec optional_nonnegative?(term()) :: boolean()
  defp optional_nonnegative?(nil), do: true
  defp optional_nonnegative?(value), do: is_integer(value) and value >= 0

  @spec valid_boot_id?(term(), boolean()) :: boolean()
  defp valid_boot_id?(nil, false), do: true
  defp valid_boot_id?(value, true), do: OverallsProtocol.uuid?(value)
  defp valid_boot_id?(_, _), do: false

  @spec stopped?(runner_observation()) :: boolean()
  defp stopped?(observation),
    do:
      observation.state == :stopped and observation.ready == false and
        is_nil(observation.qemu_pid) and is_nil(observation.backend_pid)

  @spec running_facts() :: Executor.observation()
  defp running_facts,
    do: %{
      state: :running,
      disk_present: true,
      compute_empty: false,
      cleanup_complete: false,
      guest_ready: true,
      reason: :none
    }

  @spec stopped_facts() :: Executor.observation()
  defp stopped_facts,
    do: %{
      state: :stopped,
      disk_present: true,
      compute_empty: true,
      cleanup_complete: false,
      reason: :none
    }

  # @cc [owner:ghuntley,label:security] guest-channel-current-ready-boot
  # A channel caller MUST receive only the exact current durable emulator boot
  # after a fresh owned-process and guest-readiness probe for its command. When
  # public roots are configured, readiness MUST match the private trust receipt.
  # A cached boot record alone MUST NOT grant terminal or ingress authority.
  @spec current_boot(Config.t(), Execution.command()) ::
          {:ok, GuestBoot.t()} | {:error, :execution_unavailable}
  def current_boot(config, command) do
    with true <- command.kind in [:provision, :start],
         {:ok, _spec} <- Executor.specification(command),
         true <- owned_pool?(config, command),
         :ok <- image_and_shape(command),
         {:ok, %{} = boot} <- GuestBoot.read(config.state_dir, command.placement_id),
         true <-
           boot.state == :running and boot.image_id == command.image_id and
             boot.disk_bytes == command.disk_bytes and
             boot.profile == command.profile and boot.slot == command.slot and
             boot.execution_epoch == command.execution_epoch and
             boot.generation == command.generation,
         {:ok, observed} <- guest_call("readiness", boot),
         true <-
           observed.state == :running and observed.ready and
             is_integer(observed.qemu_pid) and is_integer(observed.backend_pid),
         true <- trust_matches?(config, boot, observed.boot_id) do
      {:ok, boot}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec trust_matches?(Config.t(), GuestBoot.t(), OverallsProtocol.uuid() | nil) :: boolean()
  defp trust_matches?(%{execution: %{guest_trust_roots: [_ | _] = roots}} = config, boot, boot_id) do
    GuestTrustReceipt.read(config.state_dir, boot, roots) == {:ok, boot_id}
  end

  defp trust_matches?(_config, _boot, _boot_id), do: true

  @doc "Validated guest-vmm placement inventory; malformed or unavailable is an error."
  @spec inventory() :: {:ok, [map()]} | {:error, :execution_unavailable}
  def inventory do
    with {:ok, %{"state" => "ok", "placements" => entries} = raw} <-
           GuestRPC.call(%{"operation" => "inventory"}),
         true <- map_size(raw) == 2 and is_list(entries) and length(entries) <= 1024,
         true <- Enum.all?(entries, &valid_inventory_entry?/1),
         ids = Enum.map(entries, & &1["placement_id"]),
         true <- length(ids) == length(Enum.uniq(ids)) do
      {:ok, entries}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec valid_inventory_entry?(term()) :: boolean()
  defp valid_inventory_entry?(%{} = entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(@inventory_keys) and
      OverallsProtocol.uuid?(entry["placement_id"]) and
      (is_nil(entry["execution_epoch"]) or positive_epoch?(entry["execution_epoch"])) and
      (is_nil(entry["generation"]) or positive_epoch?(entry["generation"])) and
      entry["state"] in ["running", "stopped", "degraded", "uncertain"] and
      is_boolean(entry["live"]) and is_boolean(entry["overlay_present"]) and
      optional_pid?(entry["qemu_pid"]) and optional_pid?(entry["backend_pid"]) and
      (not entry["live"] or
         (entry["state"] == "running" and is_integer(entry["qemu_pid"]) and
            is_integer(entry["backend_pid"])))
  end

  defp valid_inventory_entry?(_), do: false

  @spec positive_epoch?(term()) :: boolean()
  defp positive_epoch?(value), do: is_integer(value) and value in 1..@maximum

  @spec retained_stopped?([map()], GuestBoot.t()) :: boolean()
  defp retained_stopped?(entries, boot) do
    Enum.any?(entries, fn entry ->
      entry["placement_id"] == boot.placement_id and
        entry["execution_epoch"] == boot.execution_epoch and
        entry["generation"] == boot.generation and entry["state"] == "stopped" and
        entry["live"] == false and entry["overlay_present"] == true and
        is_nil(entry["qemu_pid"]) and is_nil(entry["backend_pid"])
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] emulated-roster-needs-live-process
  # Roster-only boot proof MUST bind the exact durable emulator boot to pinned
  # live QEMU/backend records and measured inner-kernel PID/cgroup membership.
  # Missing or unreadable evidence MUST NOT become a watcher target.
  @impl true
  @spec boot_proof(Config.t(), Execution.command()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | {:error, atom()}
  def boot_proof(config, command) do
    with {:ok, _spec} <- Executor.specification(command),
         true <- owned_pool?(config, command),
         :ok <- image_and_shape(command),
         {:ok, %{} = boot} <- GuestBoot.read(config.state_dir, command.placement_id),
         true <- boot.state in [:launching, :running],
         true <- same_boot?(boot, command),
         {:ok, %{state: :running} = proof} <- process_proof(boot),
         {:ok, target} <- local_watch_target(proof) do
      {:ok, target}
    else
      {:ok, nil} -> {:error, :not_launched}
      {:ok, %{state: :qemu_exited}} -> {:error, :not_launched}
      _ -> {:error, :execution_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] emulated-watch-is-inner-kernel-bound
  # A running watcher MUST use the exact current guest-ready boot and a live
  # QEMU PID/start tick in its actual inner-kernel cgroup. The native watcher
  # rechecks pidfd and cgroup membership before arming; this is TCG process
  # custody, not Firecracker jail or native isolation evidence.
  @impl true
  @spec watch_target(Config.t(), Execution.command()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | :error
  def watch_target(config, command) do
    with {:ok, boot} <- current_boot(config, command),
         {:ok, %{state: :running} = proof} <- process_proof(boot),
         {:ok, target} <- local_watch_target(proof) do
      {:ok, target}
    else
      _ -> :error
    end
  end

  @spec local_watch_target(process_proof()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | {:error, :execution_unavailable}
  defp local_watch_target(%{qemu_pid: pid, qemu_start_ticks: ticks}) do
    with {:ok, ^ticks} <- proc_start_ticks(pid),
         {:ok, cgroup} <- process_cgroup(pid),
         {:ok, members} <- File.read(Path.join(cgroup, "cgroup.procs")),
         true <- Enum.member?(String.split(members, "\n", trim: true), Integer.to_string(pid)),
         {:ok, ^ticks} <- proc_start_ticks(pid) do
      {:ok, %{pid: pid, cgroup: cgroup}}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec proc_start_ticks(pos_integer()) ::
          {:ok, pos_integer()} | {:error, :execution_unavailable}
  defp proc_start_ticks(pid) do
    with {:ok, body} <- File.read("/proc/#{pid}/stat"),
         true <- byte_size(body) <= 8192 and String.starts_with?(body, "#{pid} ("),
         [_ | _] = pieces <- String.split(body, ") "),
         fields = pieces |> List.last() |> String.split(),
         state when state not in [nil, "Z", "X", "x"] <- Enum.at(fields, 0),
         ticks when is_binary(ticks) <- Enum.at(fields, 19),
         {value, ""} when value > 0 <- Integer.parse(ticks) do
      {:ok, value}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @spec process_cgroup(pos_integer()) ::
          {:ok, Path.t()} | {:error, :execution_unavailable}
  defp process_cgroup(pid) do
    with {:ok, body} <- File.read("/proc/#{pid}/cgroup"),
         true <- byte_size(body) <= 4096,
         ["0::/" <> relative] <- String.split(body, "\n", trim: true),
         true <-
           relative != "" and
             Enum.all?(String.split(relative, "/"), &(&1 not in ["", ".", ".."])),
         path = Path.join("/sys/fs/cgroup", relative),
         true <-
           File.regular?(Path.join(path, "cgroup.procs")) and
             File.regular?(Path.join(path, "cgroup.events")) do
      {:ok, path}
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  @impl true
  @spec terminal_options(Config.t(), Execution.command()) ::
          {:ok, keyword()} | {:error, :terminal_unavailable}
  def terminal_options(config, command),
    do: OverallsAntithesis.Lilly.GuestChannels.terminal_options(config, command)

  @impl true
  @spec open_ingress(Config.t(), Execution.command(), map()) :: {:error, :ingress_unavailable}
  def open_ingress(_config, _command, _binding), do: {:error, :ingress_unavailable}

  # @cc [owner:ghuntley,label:recovery] guest-inventory-before-actor-resume
  # Startup MUST reject uncertain, degraded or untracked emulator process
  # state. An RPC error is not empty inventory. Retained overlays stay tracked.
  @spec verify_units([Execution.command()]) :: :ok | {:error, :untracked_vm_units}
  def verify_units(commands) when is_list(commands) do
    ids = Enum.map(commands, & &1.placement_id)

    with true <- Enum.all?(ids, &OverallsProtocol.uuid?/1),
         true <- length(ids) == length(Enum.uniq(ids)),
         {:ok, entries} <- inventory(),
         true <- Enum.all?(entries, &(&1["state"] in ["running", "stopped"])),
         true <- Enum.all?(entries, &(&1["placement_id"] in ids)) do
      :ok
    else
      _ -> {:error, :untracked_vm_units}
    end
  end

  def verify_units(_), do: {:error, :untracked_vm_units}
end
