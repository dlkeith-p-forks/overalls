defmodule Lilly.Control.Runtime do
  @moduledoc "One-second sampling and one in-flight exchange, with exclusive host state and durable receipts."
  use GenServer
  require Lilly.Events
  alias Lilly.Control.{Client, Config, Store}
  alias Lilly.Host.{Collector, Lock, Ownership}
  alias Lilly.VM.{Actor, Executor}
  alias Lilly.Terminal.Stream

  # The hosted lower boundary is fixed while compiling the Antithesis release.
  # An ordinary release retains every native module even if runtime environment
  # variables are later changed.
  if System.get_env("ANTITHESIS_HARNESS") == "1" and
       System.get_env("ANTITHESIS_INTEGRATED_HOST") == "1" and
       System.get_env("ANTITHESIS_GUEST") == "1" do
    @guest_health_gate :integrated
    @native_execution_ready false
    @collector Collector
    @zfs_io Lilly.Host.ZFSIO
    @ownership OverallsAntithesis.Lilly.IntegratedOwnership
    @executor OverallsAntithesis.Lilly.GuestExecutor
  else
    if System.get_env("ANTITHESIS_HARNESS") == "1" do
      @native_execution_ready false
      @zfs_io OverallsAntithesis.Lilly.ZFSIO
      @ownership OverallsAntithesis.Lilly.Ownership

      # The container guest variant has no ZFS. Its STUB storage collector
      # reports a fixed synthetic pool and guest-vmm slot headroom so Marshall
      # can admit one emulated guest; nothing native is claimed.
      if System.get_env("ANTITHESIS_GUEST") == "1" do
        @guest_health_gate :stub_storage
        @collector OverallsAntithesis.Lilly.StubStorageCollector
        @executor OverallsAntithesis.Lilly.GuestExecutor
      else
        @guest_health_gate nil
        @collector OverallsAntithesis.Lilly.Collector
        @executor OverallsAntithesis.Lilly.ControlledExecutor
        @stub_storage true
      end
    else
      @guest_health_gate nil
      @stub_storage false
      @native_execution_ready true
      @collector Collector
      @zfs_io Lilly.Host.ZFSIO
      @ownership Ownership
      @executor Executor
    end
  end

  if @guest_health_gate != nil do
    # @cc [owner:ghuntley,label:capacity;verification] integrated-guest-health-before-admission
    # Only a measured guest-vmm preflight joined to this complete native sample
    # MAY set integrated execution_ready. Unknown evidence MUST remain false.
    # The container stub-storage variant MUST instead require its own labelled
    # stub report and guest-vmm preflight; it never claims native ZFS.
    if @guest_health_gate == :integrated do
      @spec guest_health?(Config.t(), OverallsProtocol.report()) :: boolean()
      defp guest_health?(config, report),
        do: OverallsAntithesis.Lilly.IntegratedHealth.ready?(config, report)
    else
      @spec guest_health?(Config.t(), OverallsProtocol.report()) :: boolean()
      defp guest_health?(config, report),
        do: OverallsAntithesis.Lilly.StubStorageHealth.ready?(config, report)
    end

    @spec mode_ready?(map()) :: boolean()
    defp mode_ready?(state) do
      case Map.get(state, :latest) do
        %{sequence: sequence, inventory: %{"execution_ready" => true}} ->
          is_integer(sequence) and sequence == Map.get(state, :delivered_report_sequence)

        _ ->
          false
      end
    end
  else
    if @stub_storage do
      # @cc [owner:ghuntley,label:capacity;verification] stub-storage-placement-readiness
      # The controlled harness release MAY advertise placement readiness only
      # from a report the selected stub substrate fully backed (measured host
      # headroom, stub pool totals, a digest-verified stub image). Its executor
      # still records requests without any execution claim.
      @spec guest_health?(Config.t(), OverallsProtocol.report()) :: boolean()
      defp guest_health?(_config, report), do: OverallsAntithesis.Lilly.StubStorage.ready?(report)
    else
      @spec guest_health?(Config.t(), OverallsProtocol.report()) :: boolean()
      defp guest_health?(_config, _report), do: @native_execution_ready
    end

    if @native_execution_ready do
      @spec mode_ready?(map()) :: boolean()
      defp mode_ready?(state), do: not is_nil(Map.get(state, :delivered_report_at))
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec terminal_actor(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def terminal_actor(server, vm_id), do: GenServer.call(server, {:terminal_actor, vm_id})

  @spec terminal_actor(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, pid()} | {:error, atom()}
  def terminal_actor(server, vm_id, placement, epoch),
    do: GenServer.call(server, {:terminal_actor, vm_id, placement, epoch})

  # @cc [owner:ghuntley,label:security] ingress-current-observed-execution
  # Local ingress MUST match the complete host/VM/placement/epoch/generation of a
  # current execution (Lilly.Execution.current/1: connected runtime, identical
  # durable intent, unexpired running observation) and its profile service
  # capability. Customer web admission and renewal MUST fail. Nested services
  # MUST require an Inception-profile command. Peer values MUST NOT select
  # executor configuration or physical paths. This is a lock-free view read.
  @doc "Internal resolution for the authenticated local connector, not a public transport."
  @spec ingress_authority(term(), map()) ::
          {:ok, pid(), {{module(), term()}, OverallsProtocol.Execution.command()}}
          | {:error, :ingress_unavailable}
  def ingress_authority(view, binding) do
    with true <- OverallsProtocol.IngressConnect.valid?(binding),
         {:ok, _version, live} <- Lilly.Execution.current(view, binding.placement_id),
         command = live.command,
         true <- command.host_id == binding.host_id,
         true <- command.kind in [:provision, :start, :resume],
         true <- OverallsProtocol.IngressConnect.valid_for_profile?(binding, command.profile),
         true <-
           Enum.all?(
             [:vm_id, :placement_id, :execution_epoch, :generation],
             &(Map.fetch!(command, &1) == Map.fetch!(binding, &1))
           ) do
      {:ok, live.actor, {live.executor, command}}
    else
      _ -> {:error, :ingress_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] private-peer-observed-execution
  # Private service identity MUST resolve exactly one current execution for the
  # Audi-attested pre-NAT address (Lilly.Execution.by_address/1) whose durable
  # provision/start profile allows SSH. Customer may resolve the physical binding
  # for the SSH-only private service; Audi must deny every other private service
  # to customer source addresses. A journal or remembered address alone MUST NOT
  # authorize. This is a lock-free view read; it never calls an actor.
  @doc "Resolve an Audi-attested pre-NAT peer address against current local execution."
  @spec private_binding(term(), binary()) ::
          {:ok, map()} | {:error, :private_service_unavailable}
  def private_binding(view, address) do
    with {:ok, _version, %{command: command}} <- Lilly.Execution.by_address(view, address),
         true <- command.kind in [:provision, :start, :resume],
         true <- OverallsProtocol.ProfilePolicy.allows?(command.profile, :private_services) do
      {:ok, Map.take(command, [:host_id, :vm_id, :placement_id, :execution_epoch])}
    else
      _ -> {:error, :private_service_unavailable}
    end
  end

  @typedoc "What a private-service subscription must watch to detect revocation."
  @type watch :: %{keys: [term()], valid_until: integer()}

  # @cc [owner:ghuntley,label:security;recovery] private-grant-watch-keys
  # private_grant/3 MUST apply exactly the private_binding/2 (services) or
  # roster_binding/2 (SSH bootstrap) policy, and return the view keys whose
  # change could alter the result plus the proof deadline, so a subscriber can
  # re-resolve on every change and at expiry.
  @spec private_grant(atom(), binary(), OverallsProtocol.PrivateServices.purpose()) ::
          {:ok, map(), watch()} | {:error, :private_service_unavailable}
  def private_grant(view, address, :services) do
    with {:ok, binding} <- private_binding(view, address),
         {:ok, _version, proof} <- Lilly.Execution.current(view, binding.placement_id) do
      {:ok, binding, watch(binding.placement_id, :live, proof)}
    else
      _ -> {:error, :private_service_unavailable}
    end
  end

  def private_grant(view, address, purpose)
      when purpose in [:ssh_roster, :ssh_host_certificate] do
    with {:ok, binding} <- roster_binding(view, address),
         {:ok, _version, proof} <- Lilly.Execution.booted(view, binding.placement_id) do
      {:ok, binding, watch(binding.placement_id, :boot, proof)}
    else
      _ -> {:error, :private_service_unavailable}
    end
  end

  defp watch(placement, row, proof),
    do: %{
      keys: [:runtime, {:intent, placement}, {row, placement}],
      valid_until: proof.valid_until
    }

  # @cc [owner:ghuntley,label:security] roster-bootstrap-live-physical-proof
  # Resolve only a unique, booted execution for the Audi-attested address
  # (Lilly.Execution.roster/2: connected runtime, identical durable intent and
  # the actor's boot row, which proves owned spec, current boot record and a
  # confined VMM). The result is roster-only; it MUST NOT enter ordinary
  # private-service admission. This is a lock-free view read.
  @spec roster_binding(atom(), binary()) ::
          {:ok, OverallsProtocol.PrivateServices.roster_binding()}
          | {:error, :private_service_unavailable}
  def roster_binding(view, address) do
    with {:boot, {:ok, _version, %{command: command}}} <-
           {:boot, Lilly.Execution.roster(view, address)},
         {:profile, true} <-
           {:profile,
            command.kind in [:provision, :start, :resume] and
              command.profile in [:customer, :oss, :standard, :inception]} do
      {:ok,
       command
       |> Map.take([:host_id, :vm_id, :placement_id, :execution_epoch, :generation])
       |> Map.put(:operation_id, command.id)}
    else
      {stage, _} -> roster_refused(stage, :unconfirmed)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] roster-refusal-closed-diagnostics
  # Refusals MUST retain closed stage/reason atoms only, never addresses, binding
  # payloads, guest account names or host command output.
  @spec roster_refused(atom(), atom()) :: {:error, :private_service_unavailable}
  defp roster_refused(stage, reason) do
    Lilly.Events.emit("lilly.roster_binding_refused", stage: stage, reason: reason)
    {:error, :private_service_unavailable}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(options, :config)

    with {:ok, global, lock} <- acquire(config) do
      case Store.open(config.state_dir, config.client.host_id, 3) do
        {:ok, store} ->
          case Store.all(store) do
            {:ok, commands} ->
              state = %{
                config: config,
                lock: lock,
                global: global,
                vm_supervisor: nil,
                actors: %{},
                actor_refs: %{},
                outcomes: %{},
                capacity_proofs: %{},
                store: store,
                view: Keyword.get(options, :view, Lilly.Execution.view()),
                phase: :connecting,
                session_id: uuid(),
                session: nil,
                sequence: 0,
                latest: nil,
                previous: nil,
                sample_task: nil,
                sample_cadence: OverallsProtocol.Cadence.new(),
                io_task: nil,
                io_cadence: OverallsProtocol.Cadence.new(),
                io_latest: nil,
                exchange_task: nil,
                exchange_report: nil,
                delivered_report_at: nil,
                delivered_report_sequence: nil,
                sent_sequence: 0,
                pending_acks: [],
                durable: Map.new(commands, &{&1.placement_id, &1}),
                retry_at: System.monotonic_time(:millisecond),
                failures: 0,
                last_error: nil,
                sample_error: nil,
                terminal: nil,
                transfer_keys: nil,
                transfer_key_retirement: nil,
                transfer_destination_revocation: nil,
                transfer_source: nil,
                inception: nil,
                clone_control: nil,
                clone_copy: nil,
                transfer_probe: nil,
                transfer_revocation: nil,
                transfer_snapshot_cleanup: nil,
                transfer_destination_cleanup: nil,
                transfer_receive: nil,
                transfer_import: nil,
                transfer_readiness: nil,
                transfer_cleanup: nil,
                terminal_ready: false,
                worker_failures: %{}
              }

              Enum.each(commands, &Lilly.Execution.intent(state.view, &1))
              state = initialize_actors(state, commands)
              send(self(), :tick)
              {:ok, state}

            {:error, _reason} ->
              Lock.release(lock)
              if global, do: Lock.release(global)
              {:stop, :invalid_state_store}
          end

        _ ->
          Lock.release(lock)
          if global, do: Lock.release(global)
          {:stop, :invalid_state_store}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp view(state), do: Map.get(state, :view, Lilly.Execution.view())

  # @cc [owner:ghuntley,label:capacity;recovery] runtime-sample-cadence
  # Host sampling MUST run through a Cadence: one sample in flight, and a tick
  # during a slow sample is dropped, so samples rest between runs. Pool
  # snapshots hold the pool lock; back-to-back samples under load starved disk
  # mutations (a clone source relaunch never acquired it). A capacity proof MUST be retained while the view still proves
  # its placement is executing (boot or live row), not only for two seconds.
  defp sample(state, event) do
    cadence = Map.get(state, :sample_cadence, OverallsProtocol.Cadence.new())

    case OverallsProtocol.Cadence.step(cadence, event) do
      {:ok, cadence, [:start]} -> start_sample(%{state | sample_cadence: cadence})
      {:ok, cadence, []} -> %{state | sample_cadence: cadence}
      {:error, :invalid_transition} -> state
    end
  end

  defp start_sample(state) do
    sequence = state.sequence + 1
    config = state.config
    previous = state.previous
    now = System.monotonic_time(:millisecond)

    proofs =
      Map.filter(state.capacity_proofs, fn {id, {at, _}} ->
        now - at <= 2000 or match?({:ok, _, _}, Lilly.Execution.booted(view(state), id))
      end)

    coverage = Map.new(proofs, fn {id, {_, proof}} -> {id, proof} end)
    images = Lilly.Host.ImageCatalog.verified(config.images)
    native_io = native_io(state, now)

    task =
      Task.async(fn ->
        case @collector.sample(
               config.pools,
               config.cgroup_path,
               previous,
               sequence,
               images,
               coverage,
               native_io
             ) do
          {:ok, report, prior} -> {:ok, report, prior, guest_health?(config, report)}
          failure -> failure
        end
      end)

    %{state | sample_task: task, sequence: sequence, capacity_proofs: proofs}
  end

  # @cc [owner:ghuntley,label:capacity] runtime-native-io-independent
  # Native pool I/O MUST be measured by its own single-flight Cadence, never
  # inside a capacity sample. A sample MUST use only the latest completed
  # measurement no older than @native_io_max_age_ms; a failed, crashed or older
  # measurement leaves I/O unavailable rather than stale.
  @native_io_max_age_ms 15_000

  defp measure_io(state, event) do
    cadence = Map.get(state, :io_cadence, OverallsProtocol.Cadence.new())

    case OverallsProtocol.Cadence.step(cadence, event) do
      {:ok, cadence, [:start]} ->
        pools = state.config.pools
        task = Task.async(fn -> @zfs_io.sample(pools) end)
        %{state | io_cadence: cadence, io_task: task}

      {:ok, cadence, []} ->
        %{state | io_cadence: cadence}

      {:error, :invalid_transition} ->
        state
    end
  end

  defp native_io(state, now) do
    case Map.get(state, :io_latest) do
      {at, io} when now - at <= @native_io_max_age_ms -> io
      _ -> %{}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  # @cc [owner:ghuntley,label:security] terminal-identity-single-placement
  # Logical-VM terminal lookup MUST resolve exactly one locally executable
  # placement and return its tracked actor only to the assigned stream. The
  # stream MUST obtain boot identity directly from that actor, preserving the
  # actor's caller fence; multiple retained runnable copies MUST fail closed.
  def handle_call(
        {:terminal_actor, id},
        {caller, _},
        %{terminal: caller, phase: :connected} = state
      ) do
    reply =
      with [command] <-
             Enum.filter(
               Map.values(state.durable),
               &(&1.vm_id == id and &1.kind in [:provision, :start, :resume])
             ),
           %{pid: pid} <- state.actors[command.placement_id] do
        {:ok, pid}
      else
        _ -> {:error, :terminal_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:terminal_actor, id, placement, epoch},
        {caller, _},
        %{terminal: caller, phase: :connected} = state
      ) do
    reply =
      with [command] <-
             Enum.filter(
               Map.values(state.durable),
               &(&1.vm_id == id and &1.kind in [:provision, :start, :resume])
             ),
           true <- command.placement_id == placement and command.execution_epoch == epoch,
           %{pid: pid} <- state.actors[placement],
           do: {:ok, pid},
           else: (_ -> {:error, :terminal_unavailable})

    {:reply, reply, state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :not_terminal_owner}, state}

  @impl true
  # A lost hostd session ends this lease (ADR-0176 decision 4).
  def handle_info({:DOWN, ref, :process, _, _}, %{lock: %Lilly.Host.Lease{monitor: ref}} = state),
    do: {:stop, :host_lock_lost, state}

  # A lost hostd session ends this lease (ADR-0176 decision 4).
  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{global: %Lilly.Host.Lease{monitor: ref}} = state
      ),
      do: {:stop, :host_lock_lost, state}

  def handle_info(:tick, %{phase: :fenced} = state), do: {:noreply, state}

  # Marshall hinted new host commands: exchange now instead of at the next
  # tick. maybe_exchange keeps the single in-flight exchange and retry backoff.
  def handle_info(:commands_hinted, state), do: {:noreply, maybe_exchange(state)}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1000)

    state = state |> measure_io(:tick) |> sample(:tick)

    {:noreply,
     state
     |> ensure_terminal()
     |> ensure_transfer_keys()
     |> ensure_transfer_key_retirement()
     |> ensure_transfer_destination_revocation()
     |> ensure_transfer_source()
     |> ensure_inception()
     |> ensure_clone(:clone_control, :control)
     |> ensure_clone(:clone_copy, :copy)
     |> ensure_transfer_probe()
     |> ensure_transfer_revocation()
     |> ensure_transfer_snapshot_cleanup()
     |> ensure_transfer_destination_cleanup()
     |> ensure_transfer_receive()
     |> ensure_transfer_import()
     |> ensure_transfer_readiness()
     |> ensure_transfer_cleanup()
     |> maybe_exchange()}
  end

  def handle_info({:vm_actor_capacity, id, pid, proof}, state) do
    if match?(%{pid: ^pid}, state.actors[id]) do
      proofs =
        if proof,
          do: Map.put(state.capacity_proofs, id, {System.monotonic_time(:millisecond), proof}),
          else: Map.delete(state.capacity_proofs, id)

      {:noreply, %{state | capacity_proofs: proofs}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{sample_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, report, previous, guest_health} ->
          report = %{
            report
            | inventory:
                report.inventory
                |> Map.put(
                  "execution_ready",
                  guest_health and state.config.execution != nil and
                    state.phase == :connected
                )
                |> Map.put("terminal_protocol", if(state.terminal_ready, do: 2, else: 0))
                |> Map.put(
                  "checkpoint_compatibility",
                  case Lilly.VM.Checkpoint.compatibility(
                         if(state.config.execution, do: state.config.execution.firecracker)
                       ) do
                    {:ok, digest} -> digest
                    _ -> nil
                  end
                )
                |> Map.put(
                  "inception_image_id",
                  Lilly.Host.InceptionProof.image_id(state.config.execution)
                )
          }

          %{state | latest: report, previous: previous, sample_task: nil, sample_error: nil}

        _ ->
          %{
            state
            | latest: nil,
              previous: nil,
              sample_task: nil,
              sample_error: :collection_failed
          }
      end

    {:noreply, state |> maybe_exchange() |> sample(:done)}
  end

  def handle_info({ref, result}, %{exchange_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | exchange_task: nil}

    state =
      case {state.phase, result} do
        {:connecting, {:ok, session}} ->
          if matching_pools?(state.config, session) do
            Lilly.Events.emit("lilly.control_connected", host_id: state.config.client.host_id)

            # Current authenticated control resumes physical reconciliation.
            Lilly.Execution.runtime_connected(view(state))

            %{state | session: session, phase: :connected, failures: 0, last_error: nil}
            |> resume_actors()
          else
            fence(state, :pool_identity_mismatch)
          end

        {:connected, {:ok, %{commands: commands, outcome_acknowledgements: ids}}} ->
          if state.failures > 0,
            do: Lilly.Events.emit("lilly.control_recovered", host_id: state.config.client.host_id)

          state
          |> delivered_report()
          |> maybe_acknowledge_outcomes(ids)
          |> receive_commands(commands)

        {_, {:error, reason}}
        when reason in [
               :stale_connection,
               :unauthorized,
               :unsupported_version,
               :machine_identity_mismatch,
               :outcome_conflict,
               :invalid_outcome
             ] ->
          fence(state, reason)

        {_, {:error, reason}} ->
          backoff(state, reason)

        _ ->
          backoff(state, :invalid_message)
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{io_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    latest =
      case result do
        {:ok, io} when is_map(io) -> {System.monotonic_time(:millisecond), io}
        _ -> nil
      end

    {:noreply, measure_io(%{state | io_task: nil, io_latest: latest}, :done)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{io_task: %Task{ref: ref}} = state),
    do: {:noreply, measure_io(%{state | io_task: nil, io_latest: nil}, :done)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sample_task: %Task{ref: ref}} = state),
    do:
      {:noreply,
       sample(
         %{
           state
           | sample_task: nil,
             latest: nil,
             previous: nil,
             sample_error: :collection_failed
         },
         :done
       )}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{exchange_task: %Task{ref: ref}} = state
      ),
      do: {:noreply, backoff(%{state | exchange_task: nil}, :transport_error)}

  def handle_info({:EXIT, pid, _}, %{vm_supervisor: pid} = state),
    do: {:stop, :vm_supervision_lost, state}

  def handle_info({:EXIT, pid, _}, %{terminal: pid} = state),
    do: {:noreply, %{state | terminal: nil, terminal_ready: false}}

  def handle_info({:terminal_stream_ready, pid, ready}, %{terminal: pid} = state)
      when is_boolean(ready) do
    if ready and not state.terminal_ready do
      Lilly.Events.emit("lilly.terminal_stream_established", host_id: state.config.client.host_id)
    end

    {:noreply, %{state | terminal_ready: ready}}
  end

  def handle_info({:terminal_stream_ready, _pid, _ready}, state), do: {:noreply, state}

  def handle_info(:terminal_probe, %{terminal: terminal} = state) when is_pid(terminal) do
    ready = Lilly.Terminal.Stream.ready?(terminal)
    previous = state.terminal_ready

    if ready and not previous do
      Lilly.Events.emit("lilly.terminal_stream_established", host_id: state.config.client.host_id)
    end

    if ready or state.phase != :connected do
      {:noreply, %{state | terminal_ready: ready}}
    else
      Process.send_after(self(), :terminal_probe, 100)
      {:noreply, state}
    end
  end

  def handle_info(:terminal_probe, state), do: {:noreply, state}

  def handle_info({:transfer_keys_fenced, pid, reason}, %{transfer_keys: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_keys_fenced, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_keys: pid} = state),
    do: {:noreply, %{state | transfer_keys: nil}}

  def handle_info(
        {:transfer_key_retirement_fenced, pid, reason},
        %{transfer_key_retirement: pid} = state
      ),
      do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_key_retirement_fenced, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_key_retirement: pid} = state),
    do: {:noreply, %{state | transfer_key_retirement: nil}}

  def handle_info(
        {:transfer_destination_revocation_fenced, pid, reason},
        %{transfer_destination_revocation: pid} = state
      ),
      do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_destination_revocation_fenced, _pid, _reason}, state),
    do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_destination_revocation: pid} = state),
    do: {:noreply, %{state | transfer_destination_revocation: nil}}

  def handle_info({:clone_fenced, pid, reason}, state)
      when pid == state.clone_control or pid == state.clone_copy,
      do: {:noreply, fence(state, reason)}

  def handle_info({:clone_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{inception: pid} = state),
    do: {:noreply, %{state | inception: nil}}

  def handle_info({:EXIT, pid, _}, %{clone_control: pid} = state),
    do: {:noreply, %{state | clone_control: nil}}

  def handle_info({:EXIT, pid, _}, %{clone_copy: pid} = state),
    do: {:noreply, %{state | clone_copy: nil}}

  def handle_info({:transfer_source_fenced, pid, reason}, %{transfer_source: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_source_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_source: pid} = state),
    do: {:noreply, %{state | transfer_source: nil}}

  def handle_info({:transfer_probe_fenced, pid, reason}, %{transfer_probe: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_probe_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_probe: pid} = state),
    do: {:noreply, %{state | transfer_probe: nil}}

  def handle_info(
        {:transfer_revocation_fenced, pid, reason},
        %{transfer_revocation: pid} = state
      ),
      do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_revocation_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_revocation: pid} = state),
    do: {:noreply, %{state | transfer_revocation: nil}}

  def handle_info(
        {:transfer_snapshot_cleanup_fenced, pid, reason},
        %{transfer_snapshot_cleanup: pid} = state
      ),
      do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_snapshot_cleanup_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_snapshot_cleanup: pid} = state),
    do: {:noreply, %{state | transfer_snapshot_cleanup: nil}}

  def handle_info(
        {:transfer_destination_cleanup_fenced, pid, reason},
        %{transfer_destination_cleanup: pid} = state
      ),
      do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_destination_cleanup_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_destination_cleanup: pid} = state),
    do: {:noreply, %{state | transfer_destination_cleanup: nil}}

  def handle_info({:transfer_readiness_fenced, pid, reason}, %{transfer_readiness: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_readiness_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_readiness: pid} = state),
    do: {:noreply, %{state | transfer_readiness: nil}}

  def handle_info({:transfer_cleanup_fenced, pid, reason}, %{transfer_cleanup: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_cleanup_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_cleanup: pid} = state),
    do: {:noreply, %{state | transfer_cleanup: nil}}

  def handle_info({:transfer_import_fenced, pid, reason}, %{transfer_import: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_import_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_import: pid} = state),
    do: {:noreply, %{state | transfer_import: nil}}

  def handle_info({:transfer_receive_fenced, pid, reason}, %{transfer_receive: pid} = state),
    do: {:noreply, fence(state, reason)}

  def handle_info({:transfer_receive_fenced, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{transfer_receive: pid} = state),
    do: {:noreply, %{state | transfer_receive: nil}}

  def handle_info({:vm_actor_ready, id, pid, pending}, state) do
    if state.vm_supervisor != nil and Map.has_key?(state.durable, id) do
      state = track_actor(state, id, pid)
      if state.phase == :connected, do: Actor.reconcile(pid)
      {:noreply, put_outcome(state, id, pending)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:vm_actor_outcome, id, pid, pending}, state) do
    if match?(%{pid: ^pid}, state.actors[id]),
      do: {:noreply, put_outcome(state, id, pending)},
      else: {:noreply, state}
  end

  def handle_info({:vm_actor_reconciled, id, pid, authority}, state) do
    case state.actors[id] do
      %{pid: ^pid} = actor ->
        {:noreply,
         %{state | actors: Map.put(state.actors, id, Map.put(actor, :reconciled, authority))}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:vm_actor_retire, id, pid, outcome}, state) do
    if match?(%{pid: ^pid}, state.actors[id]),
      do: retire_actor(state, id, pid, outcome),
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state)
      when is_map_key(state.actor_refs, ref) do
    id = state.actor_refs[ref]

    actors =
      if match?(%{pid: ^pid}, state.actors[id]),
        do: Map.delete(state.actors, id),
        else: state.actors

    {:noreply,
     %{
       state
       | actors: actors,
         actor_refs: Map.delete(state.actor_refs, ref),
         capacity_proofs: Map.delete(state.capacity_proofs, id)
     }}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Lilly.SupervisedStop.emit(:runtime, reason)

    for task <- [state.sample_task, state.exchange_task, Map.get(state, :io_task)],
        task != nil,
        do: Task.shutdown(task, :brutal_kill)

    stop_actors(state)
    stop_terminal(state)
    stop_transfer_keys(state)
    stop_transfer_key_retirement(state)
    stop_transfer_destination_revocation(state)
    stop_transfer_source(state)
    stop_clone(state, :inception)
    stop_clone(state, :clone_control)
    stop_clone(state, :clone_copy)
    stop_transfer_probe(state)
    stop_transfer_revocation(state)
    stop_transfer_snapshot_cleanup(state)
    stop_transfer_destination_cleanup(state)
    stop_transfer_receive(state)
    stop_transfer_import(state)
    stop_transfer_readiness(state)
    stop_transfer_cleanup(state)
    Lock.release(state.lock)
    if state.global, do: Lock.release(state.global)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, public_status(status.state))

  # @cc [owner:ghuntley,label:recovery] one-control-request-in-flight
  # maybe_exchange/1 MUST keep at most one outbound control request in flight and must not resend
  # a previously sent capacity sample as a fresh observation after an uncertain response.
  # A completed sample should dispatch without waiting for the next tick, unless
  # an exchange, transport backoff or fencing prevents it.
  defp maybe_exchange(%{phase: :fenced} = state), do: state

  defp maybe_exchange(%{exchange_task: %Task{}} = state), do: state

  defp maybe_exchange(state) do
    if System.monotonic_time(:millisecond) < state.retry_at do
      state
    else
      client = state.config.client
      session_id = state.session_id
      session = state.session
      report = if state.latest && state.latest.sequence > state.sent_sequence, do: state.latest
      acknowledgements = state.pending_acks

      outcomes =
        state.outcomes |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(16) |> Enum.map(&elem(&1, 1))

      task =
        if state.phase == :connecting do
          Task.async(fn -> Client.open(client, session_id) end)
        else
          Task.async(fn ->
            Client.exchange_execution(client, session, report, acknowledgements, outcomes)
          end)
        end

      %{
        state
        | exchange_task: task,
          exchange_report: if(session, do: report),
          sent_sequence: if(report && session, do: report.sequence, else: state.sent_sequence)
      }
    end
  end

  # @cc [owner:ghuntley,label:recovery] receipt-follows-durable-intent
  # receive_commands/2 MUST enqueue an acknowledgement only after rereading matching or newer
  # durable intent for the placement; unknown pools and failed/corrupt storage must fence receipt
  # processing.
  defp receive_commands(state, commands) do
    Enum.reduce_while(
      commands,
      %{state | pending_acks: [], failures: 0, last_error: nil},
      fn command, state ->
        existing = state.durable[command.placement_id]

        result =
          cond do
            not Enum.any?(state.config.pools, &(&1.id == command.pool_id)) ->
              {:error, :unknown_pool}

            existing == command ->
              {:ok, :duplicate}

            true ->
              Store.accept(state.store, command)
          end

        case result do
          {:ok, _} ->
            case Store.read(state.store, command.placement_id) do
              {:ok, current} when not is_nil(current) ->
                if current == command or
                     {current.execution_epoch, current.generation} >
                       {command.execution_epoch, command.generation} do
                  Lilly.Execution.intent(view(state), current)

                  state = %{
                    state
                    | pending_acks: [command.id | state.pending_acks],
                      durable: Map.put(state.durable, command.placement_id, current)
                  }

                  state = ensure_actor(state, current)
                  if state.phase == :fenced, do: {:halt, state}, else: {:cont, state}
                else
                  {:halt, fence(state, :command_store_failed)}
                end

              _ ->
                {:halt, fence(state, :command_store_failed)}
            end

          _ ->
            {:halt, fence(state, :command_store_failed)}
        end
      end
    )
  end

  # @cc [owner:ghuntley,label:recovery] control-backoff-bounded
  # ADR-0140: the host reports about once a second, so a long backoff saves
  # Marshall little while stretching the report gap past the host authority
  # window after Marshall itself recovers. The delay MUST start at one second,
  # double, and never exceed four seconds before jitter.
  @doc false
  @spec retry_delay(pos_integer()) :: pos_integer()
  def retry_delay(failures) when is_integer(failures) and failures > 0,
    do: min(4_000, 1000 * Integer.pow(2, min(failures, 5) - 1))

  defp backoff(state, reason) do
    if state.failures == 0 or state.last_error != reason do
      Lilly.Events.emit("lilly.control_unavailable",
        host_id: state.config.client.host_id,
        reason: reason
      )
    end

    Overalls.Diagnostics.Metrics.record([:lilly, :control, :backoff], %{count: 1}, %{})
    failures = min(state.failures + 1, 5)
    delay = retry_delay(failures) + :rand.uniform(500)

    %{
      state
      | failures: failures,
        retry_at: System.monotonic_time(:millisecond) + delay,
        last_error: reason
    }
  end

  # @cc [owner:ghuntley,label:security;recovery] fencing-stops-authority-preserves-guests
  # fence/2 MUST stop actors and the terminal stream after authentication, epoch or physical-
  # identity fencing without killing independently supervised VMMs or automatically opening a
  # replacement control session.
  defp fence(state, reason) do
    Lilly.Events.emit("lilly.control_fenced",
      host_id: state.config.client.host_id,
      reason: reason
    )

    stop_actors(state)
    stop_terminal(state)
    stop_transfer_keys(state)
    stop_transfer_key_retirement(state)
    stop_transfer_destination_revocation(state)
    stop_transfer_source(state)
    stop_clone(state, :inception)
    stop_clone(state, :clone_control)
    stop_clone(state, :clone_copy)
    stop_transfer_probe(state)
    stop_transfer_revocation(state)
    stop_transfer_snapshot_cleanup(state)
    stop_transfer_destination_cleanup(state)
    stop_transfer_receive(state)
    stop_transfer_import(state)
    stop_transfer_readiness(state)
    stop_transfer_cleanup(state)

    Lilly.Execution.runtime_disconnected(view(state))

    state = %{
      state
      | phase: :fenced,
        last_error: reason,
        vm_supervisor: nil,
        actors: %{},
        actor_refs: %{},
        terminal: nil,
        transfer_keys: nil,
        transfer_key_retirement: nil,
        transfer_destination_revocation: nil,
        transfer_source: nil,
        inception: nil,
        clone_control: nil,
        clone_copy: nil,
        transfer_probe: nil,
        transfer_revocation: nil,
        transfer_snapshot_cleanup: nil,
        transfer_destination_cleanup: nil,
        transfer_receive: nil,
        transfer_import: nil,
        transfer_readiness: nil,
        transfer_cleanup: nil,
        terminal_ready: false
    }

    Overalls.Diagnostics.Metrics.record([:lilly, :control, :fenced], %{count: 1}, %{})
    state
  end

  defp matching_pools?(config, session),
    do: Lilly.Host.Pool.session_matches?(config.pools, session.pools)

  defp public_status(state),
    do: %{
      ready: readiness(state),
      phase: state.phase,
      protocol_version: state.config.client.protocol_version,
      host_id: state.config.client.host_id,
      session_id: state.session_id,
      sample_sequence: state.sequence,
      last_error: state.last_error || state.sample_error,
      pending_acknowledgements: length(state.pending_acks),
      stored_vm_count: map_size(state.durable),
      vm_actor_count: map_size(state.actors),
      terminal_ready: state.terminal_ready,
      pending_outcomes: map_size(state.outcomes),
      sampled_at: if(state.latest, do: state.latest.sampled_at)
    }

  # @cc [owner:ghuntley,label:recovery] readiness-requires-delivered-observation
  # Readiness MUST require authenticated control, a report actually delivered in
  # this runtime within fifteen seconds of sampling, terminal stream authority and a
  # completed observation of every current placement/epoch/generation. Collection alone,
  # stale actor messages and pre-restart journals MUST NOT establish readiness.
  if @native_execution_ready or @guest_health_gate != nil do
    @spec readiness(map(), DateTime.t()) :: boolean()
    def readiness(state, now \\ DateTime.utc_now()) do
      age =
        if state.delivered_report_at,
          do: DateTime.diff(now, state.delivered_report_at, :millisecond)

      mode_ready?(state) and state.phase == :connected and
        state.terminal_ready and state.last_error == nil and
        state.sample_error == nil and is_integer(age) and age in 0..15_000 and
        Enum.all?(state.durable, fn {id, command} ->
          case state.actors[id] do
            %{reconciled: authority} ->
              authority == {command.placement_id, command.execution_epoch, command.generation}

            _ ->
              false
          end
        end)
    end
  else
    @spec readiness(map(), DateTime.t()) :: boolean()
    def readiness(_state, _now \\ DateTime.utc_now()), do: false
  end

  defp delivered_report(%{exchange_report: nil} = state), do: state

  defp delivered_report(state) do
    state
    |> Map.put(:delivered_report_at, state.exchange_report.sampled_at)
    |> Map.put(:delivered_report_sequence, Map.get(state.exchange_report, :sequence))
    |> Map.put(:exchange_report, nil)
  end

  defp uuid, do: Lilly.UUID.generate()

  defp acquire(%{execution: execution, client: %{protocol_version: 4}} = config)
       when not is_nil(execution) do
    with {:ok, global} <- @ownership.acquire(config) do
      case Lock.await(config.state_dir, 10_000) do
        {:ok, lock} ->
          {:ok, global, lock}

        error ->
          Lock.release(global)
          error
      end
    end
  end

  defp acquire(_), do: {:error, :invalid_runtime_configuration}

  # @cc [owner:ghuntley,label:security] actors-paused-until-authenticated
  # initialize_actors/2 MUST reject untracked physical units and keep restored actors paused until
  # an authenticated session confirms the configured pool identities; startup alone must not
  # launch stored commands.
  defp initialize_actors(state, commands) do
    with :ok <- @ownership.verify_units(commands),
         {:ok, supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
      Enum.reduce_while(commands, %{state | vm_supervisor: supervisor}, fn command, state ->
        state = ensure_actor(state, command)
        if state.phase == :fenced, do: {:halt, state}, else: {:cont, state}
      end)
    else
      _ -> fence(state, :vm_reconciliation_required)
    end
  end

  defp resume_actors(state) do
    Enum.each(state.actors, fn {_id, %{pid: pid}} -> Actor.reconcile(pid) end)
    state
  end

  defp ensure_actor(%{vm_supervisor: nil} = state, _), do: state

  defp ensure_actor(state, command) do
    case state.actors[command.placement_id] do
      %{pid: pid} ->
        if state.phase == :connected, do: Actor.reconcile(pid)
        state

      nil ->
        options = [
          store: state.store,
          placement_id: command.placement_id,
          vm_id: command.vm_id,
          owner: self(),
          terminal_owner: state.terminal,
          executor: {@executor, state.config},
          view: view(state)
        ]

        case DynamicSupervisor.start_child(state.vm_supervisor, {Actor, options}) do
          {:ok, pid} ->
            state = track_actor(state, command.placement_id, pid)
            if state.phase == :connected, do: Actor.reconcile(pid)
            state

          _ ->
            fence(state, :vm_actor_unavailable)
        end
    end
  end

  defp track_actor(state, id, pid) do
    case state.actors[id] do
      %{pid: ^pid} ->
        state

      existing ->
        state =
          if existing do
            Process.demonitor(existing.ref, [:flush])
            %{state | actor_refs: Map.delete(state.actor_refs, existing.ref)}
          else
            state
          end

        ref = Process.monitor(pid)

        %{
          state
          | actors: Map.put(state.actors, id, %{pid: pid, ref: ref, reconciled: nil}),
            actor_refs: Map.put(state.actor_refs, ref, id)
        }
    end
  end

  defp put_outcome(state, id, nil), do: %{state | outcomes: Map.delete(state.outcomes, id)}

  defp put_outcome(state, id, outcome),
    do: %{state | outcomes: Map.put(state.outcomes, id, outcome)}

  defp acknowledge_outcomes(state, ids) do
    Enum.each(state.actors, fn {_id, %{pid: pid}} -> Actor.acknowledge(pid, ids) end)
    %{state | outcomes: Map.reject(state.outcomes, fn {_vm, outcome} -> outcome.id in ids end)}
  end

  # @cc [owner:ghuntley,label:recovery;durability] actor-outcome-ack-independent-diagnostics
  # Physical outcome acknowledgments MUST proceed under current control authority
  # without waiting for diagnostic delivery. Diagnostic custody grants no authority.
  defp maybe_acknowledge_outcomes(state, ids), do: acknowledge_outcomes(state, ids)

  defp retire_actor(state, id, pid, outcome) do
    with %{pid: ^pid, ref: ref} <- state.actors[id],
         %{kind: :delete, generation: generation} = command <- state.durable[id],
         true <-
           generation == outcome.generation and command.execution_epoch == outcome.execution_epoch and
             command.placement_id == outcome.placement_id,
         :ok <- Store.retire(state.store, command),
         :ok <- DynamicSupervisor.terminate_child(state.vm_supervisor, pid) do
      Process.demonitor(ref, [:flush])
      Lilly.Execution.forget_intent(view(state), id)

      {:noreply,
       %{
         state
         | durable: Map.delete(state.durable, id),
           actors: Map.delete(state.actors, id),
           actor_refs: Map.delete(state.actor_refs, ref),
           outcomes: Map.delete(state.outcomes, id)
       }}
    else
      _ -> {:noreply, fence(state, :vm_retirement_failed)}
    end
  end

  defp ensure_terminal(
         %{
           phase: :connected,
           terminal: nil,
           session: %{},
           config: %{execution: execution}
         } = state
       )
       when not is_nil(execution) do
    case Stream.start_link(state.config.client, state.session, self()) do
      {:ok, pid} ->
        Enum.each(state.actors, fn {_id, actor} -> Actor.terminal_owner(actor.pid, pid) end)
        Process.send_after(self(), :terminal_probe, 100)
        %{state | terminal: pid} |> worker_started(:terminal)

      failure ->
        worker_failed(state, :terminal, failure)
    end
  end

  defp ensure_terminal(state), do: state

  defp ensure_transfer_keys(
         %{phase: :connected, transfer_keys: nil, config: %{transfer_state_dir: root}} = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.KeyRuntime.start_link(
             root: root,
             client: state.config.client,
             session: state.session,
             owner: self()
           ) do
      %{state | transfer_keys: pid} |> worker_started(:transfer_keys)
    else
      failure -> worker_failed(state, :transfer_keys, failure)
    end
  end

  defp ensure_transfer_keys(state), do: state

  defp ensure_transfer_key_retirement(
         %{phase: :connected, transfer_key_retirement: nil, config: %{transfer_state_dir: root}} =
           state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.KeyRuntime.start_link(
             mode: :retire,
             root: root,
             client: state.config.client,
             session: state.session,
             owner: self()
           ) do
      %{state | transfer_key_retirement: pid} |> worker_started(:transfer_key_retirement)
    else
      failure -> worker_failed(state, :transfer_key_retirement, failure)
    end
  end

  defp ensure_transfer_key_retirement(state), do: state

  defp ensure_transfer_destination_revocation(
         %{
           phase: :connected,
           transfer_destination_revocation: nil,
           config: %{transfer_state_dir: root}
         } =
           state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.KeyRuntime.start_link(
             mode: :cancel,
             root: root,
             client: state.config.client,
             session: state.session,
             owner: self()
           ) do
      %{state | transfer_destination_revocation: pid}
      |> worker_started(:transfer_destination_revocation)
    else
      failure -> worker_failed(state, :transfer_destination_revocation, failure)
    end
  end

  defp ensure_transfer_destination_revocation(state), do: state

  defp ensure_inception(
         %{phase: :connected, inception: nil, config: %{execution: execution}} = state
       )
       when not is_nil(execution) do
    case Lilly.Inception.Runtime.start_link(
           config: state.config,
           store: state.store,
           session: state.session
         ) do
      {:ok, pid} -> %{state | inception: pid}
      _ -> state
    end
  end

  defp ensure_inception(state), do: state

  defp ensure_clone(%{phase: :connected, config: %{transfer_state_dir: root}} = state, key, mode)
       when is_binary(root) do
    if state[key] == nil do
      with :ok <- Lilly.Host.PrivateFiles.directory(root),
           {:ok, pid} <-
             Lilly.Clone.Runtime.start_link(
               config: state.config,
               store: state.store,
               session: state.session,
               owner: self(),
               mode: mode
             ),
           do: Map.put(state, key, pid) |> worker_started(key),
           else: (failure -> worker_failed(state, key, failure))
    else
      state
    end
  end

  defp ensure_clone(state, _, _), do: state

  # @cc [owner:ghuntley,label:recovery;observability] control-worker-diagnostics-deduped
  # Worker start failures MUST report only the fixed utility and closed reason
  # atoms, and identical consecutive failures MUST be suppressed until the
  # worker starts or the reason changes; ticking retries MUST NOT spam events.
  defp worker_started(state, utility),
    do: %{state | worker_failures: Map.delete(state.worker_failures, utility)}

  defp worker_failed(state, utility, failure) do
    reason =
      case failure do
        {:error, reason} when is_atom(reason) -> reason
        _ -> :worker_start_failed
      end

    if state.worker_failures[utility] != reason do
      Lilly.Events.emit("lilly.control_worker_unavailable", utility: utility, reason: reason)
    end

    %{state | worker_failures: Map.put(state.worker_failures, utility, reason)}
  end

  defp stop_clone(state, key) do
    if pid = state[key] do
      try do
        GenServer.stop(pid, :normal, 5000)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end
    end

    :ok
  end

  defp ensure_transfer_source(
         %{
           phase: :connected,
           transfer_source: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.SourceRuntime.start_link(
             config: state.config,
             store: state.store,
             session: state.session,
             owner: self()
           ),
         do: %{state | transfer_source: pid} |> worker_started(:transfer_source),
         else: (failure -> worker_failed(state, :transfer_source, failure))
  end

  defp ensure_transfer_source(state), do: state
  defp stop_transfer_source(%{transfer_source: nil}), do: :ok

  defp stop_transfer_source(%{transfer_source: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_probe(
         %{
           phase: :connected,
           transfer_probe: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.SourceRuntime.start_link(
             mode: :probe,
             config: state.config,
             store: state.store,
             session: state.session,
             owner: self()
           ),
         do: %{state | transfer_probe: pid} |> worker_started(:transfer_probe),
         else: (failure -> worker_failed(state, :transfer_probe, failure))
  end

  defp ensure_transfer_probe(state), do: state
  defp stop_transfer_probe(%{transfer_probe: nil}), do: :ok

  defp stop_transfer_probe(%{transfer_probe: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_revocation(
         %{
           phase: :connected,
           transfer_revocation: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.SourceRuntime.start_link(
             mode: :revoke,
             config: state.config,
             store: state.store,
             session: state.session,
             owner: self()
           ),
         do: %{state | transfer_revocation: pid} |> worker_started(:transfer_revocation),
         else: (failure -> worker_failed(state, :transfer_revocation, failure))
  end

  defp ensure_transfer_revocation(state), do: state
  defp stop_transfer_revocation(%{transfer_revocation: nil}), do: :ok

  defp stop_transfer_revocation(%{transfer_revocation: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_snapshot_cleanup(
         %{
           phase: :connected,
           transfer_snapshot_cleanup: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.SourceRuntime.start_link(
             mode: :prune,
             config: state.config,
             store: state.store,
             session: state.session,
             owner: self()
           ),
         do:
           %{state | transfer_snapshot_cleanup: pid} |> worker_started(:transfer_snapshot_cleanup),
         else: (failure -> worker_failed(state, :transfer_snapshot_cleanup, failure))
  end

  defp ensure_transfer_snapshot_cleanup(state), do: state
  defp stop_transfer_snapshot_cleanup(%{transfer_snapshot_cleanup: nil}), do: :ok

  defp stop_transfer_snapshot_cleanup(%{transfer_snapshot_cleanup: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_destination_cleanup(
         %{
           phase: :connected,
           transfer_destination_cleanup: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.SourceRuntime.start_link(
             mode: :destination_cleanup,
             config: state.config,
             store: state.store,
             session: state.session,
             owner: self()
           ),
         do:
           %{state | transfer_destination_cleanup: pid}
           |> worker_started(:transfer_destination_cleanup),
         else: (failure -> worker_failed(state, :transfer_destination_cleanup, failure))
  end

  defp ensure_transfer_destination_cleanup(state), do: state
  defp stop_transfer_destination_cleanup(%{transfer_destination_cleanup: nil}), do: :ok

  defp stop_transfer_destination_cleanup(%{transfer_destination_cleanup: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_receive(
         %{
           phase: :connected,
           transfer_receive: nil,
           config: %{transfer_state_dir: root}
         } = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.ReceiveRuntime.start_link(
             config: state.config,
             session: state.session,
             owner: self()
           ),
         do: %{state | transfer_receive: pid} |> worker_started(:transfer_receive),
         else: (failure -> worker_failed(state, :transfer_receive, failure))
  end

  defp ensure_transfer_receive(state), do: state
  defp stop_transfer_receive(%{transfer_receive: nil}), do: :ok

  defp stop_transfer_receive(%{transfer_receive: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_import(
         %{phase: :connected, transfer_import: nil, config: %{transfer_state_dir: root}} = state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.ReceiveRuntime.start_link(
             config: state.config,
             session: state.session,
             mode: :import,
             owner: self()
           ),
         do: %{state | transfer_import: pid} |> worker_started(:transfer_import),
         else: (failure -> worker_failed(state, :transfer_import, failure))
  end

  defp ensure_transfer_import(state), do: state
  defp stop_transfer_import(%{transfer_import: nil}), do: :ok

  defp stop_transfer_import(%{transfer_import: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_readiness(
         %{phase: :connected, transfer_readiness: nil, config: %{transfer_state_dir: root}} =
           state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.ReceiveRuntime.start_link(
             config: state.config,
             store: state.store,
             session: state.session,
             mode: :readiness,
             owner: self()
           ),
         do: %{state | transfer_readiness: pid} |> worker_started(:transfer_readiness),
         else: (failure -> worker_failed(state, :transfer_readiness, failure))
  end

  defp ensure_transfer_readiness(state), do: state
  defp stop_transfer_readiness(%{transfer_readiness: nil}), do: :ok

  defp stop_transfer_readiness(%{transfer_readiness: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp ensure_transfer_cleanup(
         %{phase: :connected, transfer_cleanup: nil, config: %{transfer_state_dir: root}} =
           state
       )
       when is_binary(root) do
    with :ok <- Lilly.Host.PrivateFiles.directory(root),
         {:ok, pid} <-
           Lilly.Transfer.ReceiveRuntime.start_link(
             config: state.config,
             store: state.store,
             session: state.session,
             mode: :cleanup,
             owner: self()
           ),
         do: %{state | transfer_cleanup: pid} |> worker_started(:transfer_cleanup),
         else: (failure -> worker_failed(state, :transfer_cleanup, failure))
  end

  defp ensure_transfer_cleanup(state), do: state
  defp stop_transfer_cleanup(%{transfer_cleanup: nil}), do: :ok

  defp stop_transfer_cleanup(%{transfer_cleanup: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp stop_transfer_keys(%{transfer_keys: nil}), do: :ok

  defp stop_transfer_keys(%{transfer_keys: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp stop_transfer_key_retirement(%{transfer_key_retirement: nil}), do: :ok

  defp stop_transfer_key_retirement(%{transfer_key_retirement: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp stop_transfer_destination_revocation(%{transfer_destination_revocation: nil}), do: :ok

  defp stop_transfer_destination_revocation(%{transfer_destination_revocation: pid}) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp stop_terminal(%{terminal: nil}), do: :ok

  defp stop_terminal(state) do
    try do
      GenServer.stop(state.terminal, :normal, 5000)
    catch
      :exit, _ -> Process.exit(state.terminal, :kill)
    end

    :ok
  end

  defp stop_actors(%{vm_supervisor: nil}), do: :ok

  defp stop_actors(state) do
    if Process.alive?(state.vm_supervisor) do
      try do
        Supervisor.stop(state.vm_supervisor, :shutdown, 10_000)
      catch
        :exit, _ ->
          Enum.each(state.actors, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
          Process.exit(state.vm_supervisor, :kill)
      end
    end

    Enum.each(state.actor_refs, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    :ok
  end
end
