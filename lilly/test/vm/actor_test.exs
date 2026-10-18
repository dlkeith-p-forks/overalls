defmodule Lilly.VM.ActorTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.{Runtime, Store}
  alias Lilly.Execution
  alias Lilly.Network.Attribution
  alias Lilly.VM.Actor
  @id "11111111-1111-4111-8111-111111111111"
  @moduletag :tmp_dir

  defmodule ControlledExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(owner, command, history) do
      # The launch commit check is a per-task closure; the pinned history is
      # the durable epoch/generation (ADR-0176).
      send(owner, {:execute, self(), command, Map.delete(history, :commit)})

      receive do
        {:result, result} -> result
      end
    end
  end

  defmodule SocketExecutor do
    @behaviour Lilly.VM.Executor
    @id "11111111-1111-4111-8111-111111111111"
    @impl true
    def reconcile(_, _, _),
      do:
        {:ok,
         %{
           state: :running,
           compute_empty: false,
           disk_present: true,
           cleanup_complete: false,
           reason: :none
         }}

    @impl true
    def terminal_options(vsock_path, _),
      do:
        {:ok,
         [
           vsock_path: vsock_path,
           boot_challenge: "cafebabe",
           placement_id: @id,
           execution_epoch: 1
         ]}
  end

  defmodule DiagnosticExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    @spec reconcile({pid(), Path.t()}, map(), map()) :: Lilly.VM.Executor.result()
    def reconcile({owner, _directory}, command, history),
      do: ControlledExecutor.reconcile(owner, command, history)

    @impl true
    @spec boot_log({pid(), Path.t()}, map(), non_neg_integer()) ::
            {:ok, Lilly.VM.BootLog.page()} | {:error, atom()}
    def boot_log({_owner, directory}, command, cursor) do
      Lilly.VM.BootLog.read(
        directory,
        command.placement_id,
        {command.execution_epoch, command.generation},
        cursor
      )
    end
  end

  defmodule BlockingDiagnosticExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    @spec reconcile(pid(), map(), map()) :: Lilly.VM.Executor.result()
    def reconcile(owner, command, history),
      do: ControlledExecutor.reconcile(owner, command, history)

    @impl true
    @spec boot_log(pid(), map(), non_neg_integer()) :: {:ok, Lilly.VM.BootLog.page()}
    def boot_log(owner, _command, cursor) do
      send(owner, {:diagnostic_read_started, self()})

      receive do
        :finish_diagnostic_read -> {:ok, %{next: cursor + 7, bytes: "private"}}
      end
    end
  end

  test "pending and failed actors expose current boot diagnostics without terminal identity",
       context do
    directory = Path.join(context.tmp_dir, "diagnostic")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    for {name, bytes} <- [
          {"boot.json",
           JSON.encode!(%{
             "version" => 1,
             "placement_id" => @id,
             "execution_epoch" => 1,
             "generation" => 1,
             "boot_challenge" => String.duplicate("a", 64)
           })},
          {"intent.bin", <<@id::binary, 1::64, 1::64, 1>>},
          {"launch-attempt.bin", <<@id::binary, 1::64, 1::64>>},
          {"boot.log", "startup failure"}
        ] do
      path = Path.join(directory, name)
      File.write!(path, bytes)
      File.chmod!(path, 0o600)
    end

    options =
      Keyword.merge(context.options,
        executor: {DiagnosticExecutor, {self(), directory}},
        terminal_owner: self()
      )

    actor = start_supervised!({Actor, options})
    assert {:error, :boot_log_unavailable} = Actor.boot_log(actor, @id, 0)
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    assert {:ok, %{next: 15, bytes: "startup failure"}} = Actor.boot_log(actor, @id, 0)
    assert {:error, :terminal_unavailable} = Actor.terminal_identity(actor, @id)
    assert {:error, :boot_log_unavailable} = Actor.boot_log(actor, Lilly.UUID.generate(), 0)

    unauthorized = Task.async(fn -> Actor.boot_log(actor, @id, 0) end)
    assert {:error, :not_terminal_owner} = Task.await(unauthorized)

    File.write!(Path.join(directory, "intent.bin"), <<@id::binary, 1::64, 1::64, 3>>)

    send(
      task,
      {:result,
       {:ok, %{running() | state: :failed, compute_empty: true, reason: :execution_failed}}}
    )

    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :failed}}, 2000
    assert {:ok, %{next: 15, bytes: "startup failure"}} = Actor.boot_log(actor, @id, 0)
    assert {:error, :terminal_unavailable} = Actor.terminal_identity(actor, @id)

    {:ok, :stored} = accept(context, command(2, :stop))
    assert {:error, :boot_log_unavailable} = Actor.boot_log(actor, @id, 0)
  end

  test "a durable command superseded during a diagnostic read discards its bytes", context do
    options = Keyword.put(context.options, :executor, {BlockingDiagnosticExecutor, self()})
    actor = start_supervised!({Actor, options})
    Actor.reconcile(actor)
    assert_receive {:execute, _, _, _}, 2000

    reader =
      Task.async(fn ->
        receive do
          :read -> Actor.boot_log(actor, @id, 0)
        end
      end)

    assert :ok = Actor.terminal_owner(actor, reader.pid)
    send(reader.pid, :read)
    assert_receive {:diagnostic_read_started, ^actor}
    {:ok, :stored} = accept(context, command(2, :stop))
    send(actor, :finish_diagnostic_read)
    assert {:error, :boot_log_unavailable} = Task.await(reader)
  end

  test "terminal identity requires the current running generation and denies supersession",
       context do
    vsock_path = "/tmp/ltv-" <> Lilly.UUID.generate()

    options =
      Keyword.merge(context.options,
        executor: {SocketExecutor, vsock_path},
        terminal_owner: self()
      )

    actor = start_supervised!({Actor, options})

    assert {:error, :terminal_unavailable} = Actor.terminal_identity(actor, @id)

    Actor.reconcile(actor)
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000

    assert {:ok, identity} = Actor.terminal_identity(actor, @id)
    assert identity.uds_path == vsock_path
    assert identity.placement_id == @id
    assert identity.execution_epoch == 1
    assert identity.boot_challenge == "cafebabe"

    assert {:error, :terminal_unavailable} = Actor.terminal_identity(actor, Lilly.UUID.generate())

    task = Task.async(fn -> Actor.terminal_owner(actor, self()) end)
    assert {:error, :not_terminal_owner} = Task.await(task)

    {:ok, :stored} = accept(context, command(2, :stop))
    Actor.reconcile(actor)

    assert {:error, :terminal_unavailable} = Actor.terminal_identity(actor, @id)
  end

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @id, 3)
    first = command(1, :provision)
    {:ok, :stored} = Store.accept(store, first)
    view = :"actor_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, first)

    options = [
      store: store,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      owner: self(),
      executor: {ControlledExecutor, self()},
      view: view
    ]

    %{store: store, first: first, options: options, view: view}
  end

  test "egress binds a kernel label and source to a fresh durable VM owner", context do
    command = command(2, :start)
    owner = command.owner_id
    {:ok, :stored} = accept(context, command)
    {:ok, label} = Lilly.Network.FlowLabel.token(@id, command)
    source = {10, 10, 0, 2}
    actor = start_supervised!({Actor, context.options})
    assert {:error, :unresolved} = Attribution.identity(context.view, label, source)
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000

    expected = %{
      host_id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      generation: 2,
      owner_id: owner,
      attribution: :resolved
    }

    assert {:ok, _, ^expected} = Attribution.identity(context.view, label, source)
    assert {:error, :unresolved} = Attribution.identity(context.view, label, {10, 10, 0, 3})
    {:ok, old_label} = Lilly.Network.FlowLabel.token(@id, context.first)
    assert {:error, :unresolved} = Attribution.identity(context.view, old_label, source)

    # Retaining an actor or journal cannot retain authority after durable stop.
    {:ok, :stored} = accept(context, command(3, :stop))
    assert {:error, :unresolved} = Attribution.identity(context.view, label, source)
  end

  test "ingress needs fresh observed execution and exact durable identity", context do
    actor = start_supervised!({Actor, context.options})
    binding = ingress_binding()
    assert {:error, :ingress_unavailable} = Runtime.ingress_authority(context.view, binding)
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000
    assert {:ok, ^actor, {_, command}} = Runtime.ingress_authority(context.view, binding)
    assert command == context.first

    for key <- [:host_id, :placement_id, :session_id] do
      changed = Map.put(binding, key, Lilly.UUID.generate())
      # Session IDs belong to Marshall; only execution identity is locally fenced.
      if key == :session_id,
        do: assert(match?({:ok, _, _}, Runtime.ingress_authority(context.view, changed))),
        else:
          assert(
            {:error, :ingress_unavailable} == Runtime.ingress_authority(context.view, changed)
          )
    end

    for key <- [:execution_epoch, :generation] do
      assert {:error, :ingress_unavailable} =
               Runtime.ingress_authority(context.view, Map.put(binding, key, 2))
    end

    {:ok, :stored} = accept(context, command(2, :stop))
    assert {:error, :ingress_unavailable} = Runtime.ingress_authority(context.view, binding)
  end

  test "restored running journals cannot authorize before a new physical observation", context do
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000
    stop_supervised!(Actor)
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, _, _, _}, 2000

    assert {:error, :ingress_unavailable} =
             Runtime.ingress_authority(context.view, ingress_binding())
  end

  # @cc [owner:ghuntley,label:verification;security] restored-journal-is-not-egress-authority
  # After an actor restart, the recovered journal alone MUST NOT resolve egress
  # attribution: even a restored running outcome of an owned command needs a
  # fresh observation by the new incarnation first.
  test "a restored journal cannot resolve egress before a fresh running observation",
       context do
    owned = command(2, :start)
    owner = owned.owner_id
    {:ok, :stored} = accept(context, owned)
    {:ok, label} = Lilly.Network.FlowLabel.token(@id, owned)
    source = {10, 10, 0, 2}
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, task, ^owned, _}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000
    assert {:ok, _, _} = Attribution.identity(context.view, label, source)
    stop_supervised!(Actor)

    restored = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^restored, %{state: :running}}, 2000
    assert {:error, :unresolved} = Attribution.identity(context.view, label, source)
    Actor.reconcile(restored)
    assert_receive {:execute, resumed, ^owned, _}, 2000
    assert {:error, :unresolved} = Attribution.identity(context.view, label, source)
    send(resumed, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^restored, %{state: :running}}, 2000
    assert {:ok, _, resolved} = Attribution.identity(context.view, label, source)
    assert resolved.attribution == :resolved
    assert resolved.owner_id == owner

    # Retained ownership follows only the current durable command: a durable stop
    # supersedes the observed incarnation and resolves nothing.
    {:ok, :stored} = accept(context, command(3, :stop))
    assert {:error, :unresolved} = Attribution.identity(context.view, label, source)
  end

  test "an old running observation expires while reconciliation is stalled", context do
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000
    assert {:ok, _, _} = Runtime.ingress_authority(context.view, ingress_binding())
    # The next controlled reconcile deliberately never supplies a fresh outcome.
    Process.sleep(2100)

    assert {:error, :ingress_unavailable} =
             Runtime.ingress_authority(context.view, ingress_binding())
  end

  defp ingress_binding do
    %{
      host_id: @id,
      vm_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      service: :ssh,
      port: 22,
      label: OverallsProtocol.IngressName.label("vm", @id)
    }
  end

  test "two placements of one VM keep independent actors, paths and journals", context do
    placement = Lilly.UUID.generate()

    second = %{
      command(1, :start)
      | id: Lilly.UUID.generate(),
        placement_id: placement,
        execution_epoch: 2
    }

    assert {:ok, :stored} = accept(context, second)
    source = start_supervised!(Supervisor.child_spec({Actor, context.options}, id: :source_copy))
    options = Keyword.put(context.options, :placement_id, placement)

    destination =
      start_supervised!(Supervisor.child_spec({Actor, options}, id: :destination_copy))

    assert_receive {:vm_actor_ready, @id, ^source, nil}
    assert_receive {:vm_actor_ready, ^placement, ^destination, nil}
    Actor.reconcile(destination)
    assert_receive {:execute, task, ^second, %{running_epoch: 0, running_generation: 0}}, 2000
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, ^placement, ^destination, outcome}, 2000
    assert outcome.vm_id == @id
    assert outcome.placement_id == placement
    assert Actor.status(source).outcome_sequence == 0
    assert Actor.status(destination).outcome_sequence == 1

    {:ok, first_spec} = Lilly.VM.Executor.specification(context.first)
    {:ok, second_spec} = Lilly.VM.Executor.specification(second)
    assert first_spec.id == @id
    assert second_spec.id == placement
    assert first_spec.network.address == second_spec.network.address
    assert first_spec.network.mac == second_spec.network.mac
    refute first_spec.network.tap == second_spec.network.tap
    refute Lilly.VM.Unit.name(first_spec) == Lilly.VM.Unit.name(second_spec)
  end

  test "actors remain paused until authenticated, then persist and restore pending outcomes",
       context do
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    refute Actor.status(actor).active
    refute_received {:execute, _, _, _}
    Actor.reconcile(actor)
    assert_receive {:execute, task, first, %{running_generation: 0}}, 2000
    assert first == context.first
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
    assert outcome.state == :running
    assert outcome.sequence == 1
    stop_supervised!(Actor)
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, ^outcome}, 2000
    Actor.acknowledge(replacement, [outcome.id])
    assert_receive {:vm_actor_outcome, @id, ^replacement, nil}, 2000
    Actor.reconcile(replacement)
    assert_receive {:execute, next, _, %{running_generation: 1}}, 2000
    send(next, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^replacement, nil}, 2000
    assert Actor.status(replacement).outcome_sequence == 1
  end

  # @cc [owner:ghuntley,label:verification;concurrency] unchanged-reconcile-casts-rest
  # Repeated unchanged :reconcile casts during a run MUST NOT start a follow-up
  # on completion (the actor rests until its next tick), while a changed
  # durable command MUST start at once.
  test "unchanged reconcile casts do not chain reconciles; a changed command starts at once",
       context do
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, first_task, _, _}, 2000
    Enum.each(1..5, fn _ -> Actor.reconcile(actor) end)
    # The casts are processed before the result: GenServer mailbox order.
    _ = :sys.get_state(actor)
    send(first_task, {:result, {:retry, :storage_busy}})
    refute_receive {:execute, _, _, _}, 300

    stop = command(2, :stop)
    {:ok, :stored} = accept(context, stop)
    Actor.reconcile(actor)
    assert_receive {:execute, _task, ^stop, _}, 500
  end

  # @cc [owner:ghuntley,label:verification;recovery] actor-journal-contention-not-fatal
  # A journal write that meets another authoritative writer's lock for longer than the
  # bounded wait MUST defer (nothing recorded) instead of stopping the actor;
  # a later reconcile records the outcome.
  test "audit-lock contention defers an outcome instead of stopping the actor", context do
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    directory = :sys.get_state(actor).journal.directory
    parent = self()

    holder =
      spawn(fn ->
        {:ok, lock} = Lilly.Host.Lock.acquire(Path.join(directory, "audit-lock"))
        send(parent, :locked)

        receive do
          :release -> Lilly.Host.Lock.release(lock)
        end
      end)

    assert_receive :locked, 5000
    send(task, {:result, {:ok, running()}})
    # The record waits two seconds for the lock, then defers.
    Process.sleep(2500)
    assert Process.alive?(actor)
    refute_received {:vm_actor_outcome, @id, ^actor, _}

    send(holder, :release)
    assert_receive {:execute, next, _, _}, 5000
    send(next, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 5000
  end

  test "a superseded in-flight result cannot become the new command's outcome", context do
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, old_task, _, _}, 2000
    stop = command(2, :stop)
    {:ok, :stored} = accept(context, stop)
    Actor.reconcile(actor)
    send(old_task, {:result, {:ok, running()}})
    assert_receive {:execute, task, ^stop, %{running_generation: 0}}, 2000
    refute_received {:vm_actor_outcome, @id, ^actor, _}

    stopped = %{
      state: :stopped,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    send(task, {:result, {:ok, stopped}})
    assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
    assert outcome.generation == 2
    assert outcome.state == :stopped
  end

  test "an in-flight older epoch cannot publish after authority is renewed", context do
    old = command(100, :start)
    {:ok, :stored} = accept(context, old)
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, old_task, ^old, _}, 2000
    fresh = %{command(2, :start) | execution_epoch: 2}
    {:ok, :stored} = accept(context, fresh)
    send(old_task, {:result, {:ok, running()}})
    assert_receive {:execute, task, ^fresh, %{running_epoch: 0}}, 2000
    refute_received {:vm_actor_outcome, @id, ^actor, _}
    send(task, {:result, {:ok, running()}})
    assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
    assert outcome.execution_epoch == 2
    assert outcome.generation == 2
    stop_supervised!(Actor)
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, ^outcome}
  end

  # @cc [owner:ghuntley,label:verification;recovery] generated-superseded-results-stay-old
  # A completed executor task for an older revision MUST NOT publish after
  # durable intent advances, even when the replacement changes epoch or kind.
  @tag :hegel
  test "generated supersession histories publish only the current revision", context do
    check all(
            newer_epoch? <- boolean(),
            next_generation <- integer(2..30),
            kind <- member_of([:start, :stop]),
            test_cases: 25
          ) do
      directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      {:ok, store} = Store.open(directory, @id, 3)
      first = command(1, :provision)
      assert {:ok, :stored} = Store.accept(store, first)
      options = Keyword.put(context.options, :store, store)
      actor = start_supervised!({Actor, options})
      assert_receive {:vm_actor_ready, @id, ^actor, nil}, 2_000
      Actor.reconcile(actor)
      assert_receive {:execute, old_task, ^first, _}, 2_000

      replacement =
        if newer_epoch? do
          %{command(next_generation, kind) | execution_epoch: 2}
        else
          command(next_generation, kind)
        end

      assert {:ok, :stored} = Store.accept(store, replacement)
      send(old_task, {:result, {:ok, running()}})
      assert_receive {:execute, current_task, ^replacement, %{running_generation: 0}}, 2_000
      refute_received {:vm_actor_outcome, @id, ^actor, _}

      observation =
        if kind == :stop,
          do: %{running() | state: :stopped, compute_empty: true},
          else: running()

      send(current_task, {:result, {:ok, observation}})
      assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2_000
      assert outcome.execution_epoch == replacement.execution_epoch
      assert outcome.generation == replacement.generation
      assert outcome.state == observation.state
      assert outcome.sequence == 1
      stop_supervised!(Actor)

      replacement_actor = start_supervised!({Actor, options})
      assert_receive {:vm_actor_ready, @id, ^replacement_actor, ^outcome}, 2_000
      stop_supervised!(Actor)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] generated-journal-before-effect
  # For every generated execution revision, the journal MUST contain its
  # attempted epoch and generation before the executor can return any effect.
  @tag :hegel
  test "generated revisions are durably attempted before executor work", context do
    check all(
            epoch <- integer(1..8),
            generation <- integer(1..100),
            kind <- member_of([:provision, :start]),
            test_cases: 25
          ) do
      directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      {:ok, store} = Store.open(directory, @id, 3)
      intent = %{command(generation, kind) | execution_epoch: epoch}
      assert {:ok, :stored} = Store.accept(store, intent)
      actor = start_supervised!({Actor, Keyword.put(context.options, :store, store)})
      assert_receive {:vm_actor_ready, @id, ^actor, nil}, 2_000
      Actor.reconcile(actor)
      assert_receive {:execute, worker, ^intent, _}, 2_000

      path = Path.join([directory, "actors", @id, "journal.json"])
      {:ok, bytes} = Lilly.Host.PrivateFiles.read_secret(path)
      assert {:ok, payload, _metadata} = Lilly.Lifecycle.Journal.envelope(bytes)
      assert payload["attempted_epoch"] == epoch
      assert payload["attempted_generation"] == generation
      assert payload["outcome"] == nil

      send(worker, {:result, {:ok, running()}})
      assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2_000
      stop_supervised!(Actor)
    end
  end

  test "lock deferral preserves a confirmed stopped outcome across actor restart", context do
    stopped_command = command(2, :stop)
    {:ok, :stored} = accept(context, stopped_command)
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, task, ^stopped_command, _}, 2000

    send(
      task,
      {:result,
       {:ok,
        %{
          state: :stopped,
          compute_empty: true,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        }}}
    )

    assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
    assert outcome.state == :stopped
    Actor.reconcile(actor)
    assert_receive {:execute, next, ^stopped_command, _}, 2000
    ref = Process.monitor(next)
    send(next, {:result, {:retry, :network_unavailable}})
    assert_receive {:DOWN, ^ref, :process, ^next, :normal}, 2000
    _ = :sys.get_state(actor)
    assert Actor.status(actor).outcome_sequence == outcome.sequence
    refute_received {:vm_actor_outcome, @id, ^actor, %{state: :unknown}}
    stop_supervised!(Actor)
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, ^outcome}, 2000
  end

  # @cc [owner:ghuntley,label:verification;recovery] transient-restart-histories-retain-fences
  # Generated retry/restart histories MUST retain the exact command and durable
  # stopped outcome until an executor supplies a confirmed result. This tests
  # actor persistence only; native fixtures separately prove no VMM launch.
  @tag :hegel
  test "storage retry histories preserve authority and observations until success or failure",
       context do
    check all(
            restarts <- list_of(boolean(), min_length: 1, max_length: 8),
            terminal? <- boolean(),
            test_cases: 20
          ) do
      directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      {:ok, store} = Store.open(directory, @id, 3)
      stopped_command = command(2, :stop)
      {:ok, :stored} = Store.accept(store, stopped_command)
      options = Keyword.put(context.options, :store, store)
      actor = start_supervised!({Actor, options})
      assert_receive {:vm_actor_ready, @id, ^actor, nil}, 2000
      Actor.reconcile(actor)
      assert_receive {:execute, task, ^stopped_command, history}, 2000
      stopped = %{running() | state: :stopped, compute_empty: true}
      send(task, {:result, {:ok, stopped}})
      assert_receive {:vm_actor_outcome, @id, ^actor, previous}, 2000
      restart = command(3, :start)
      {:ok, :stored} = Store.accept(store, restart)

      actor =
        Enum.reduce(restarts, actor, fn reboot?, current ->
          Actor.reconcile(current)
          assert_receive {:execute, worker, ^restart, ^history}, 2000
          monitor = Process.monitor(worker)
          send(worker, {:result, {:retry, :storage_busy}})
          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
          await_idle(current, System.monotonic_time(:millisecond) + 2000)
          assert Actor.status(current).outcome_sequence == previous.sequence
          assert {:ok, ^restart} = Store.read(store, @id)
          refute_received {:vm_actor_outcome, @id, ^current, _}

          if reboot? do
            stop_supervised!(Actor)
            replacement = start_supervised!({Actor, options})
            assert_receive {:vm_actor_ready, @id, ^replacement, ^previous}, 2000
            replacement
          else
            current
          end
        end)

      Actor.reconcile(actor)
      assert_receive {:execute, worker, ^restart, ^history}, 2000

      final =
        if terminal?,
          do: %{stopped | state: :failed, reason: :execution_failed},
          else: running()

      send(worker, {:result, {:ok, final}})
      assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
      assert outcome.state == final.state
      assert outcome.sequence == previous.sequence + 1

      assert Map.take(outcome, [:placement_id, :execution_epoch, :generation]) ==
               Map.take(restart, [:placement_id, :execution_epoch, :generation])

      stop_supervised!(Actor)
      recovered = start_supervised!({Actor, options})
      assert_receive {:vm_actor_ready, @id, ^recovered, ^outcome}, 2000
      stop_supervised!(Actor)
    end
  end

  @spec await_idle(pid(), integer()) :: :ok
  defp await_idle(actor, deadline) do
    if :sys.get_state(actor).task == nil do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      await_idle(actor, deadline)
    end
  end

  test "actor termination kills its worker while the journal remains recoverable", context do
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, task, _, _}, 2000
    monitor = Process.monitor(task)
    stop_supervised!(Actor)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 2000
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, nil}, 2000
    assert Actor.status(replacement).generation == 1
  end

  test "only an acknowledged current deletion retires, including after restart", context do
    deletion = command(2, :delete)
    {:ok, :stored} = accept(context, deletion)
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, task, ^deletion, _}, 2000

    send(
      task,
      {:result,
       {:ok,
        %{
          state: :deleted,
          compute_empty: true,
          disk_present: false,
          cleanup_complete: true,
          reason: :none
        }}}
    )

    assert_receive {:vm_actor_outcome, @id, ^actor, outcome}, 2000
    refute_received {:vm_actor_retire, _, _, _}
    Actor.acknowledge(actor, [Lilly.UUID.generate()])
    assert_receive {:vm_actor_outcome, @id, ^actor, ^outcome}, 2000
    refute_received {:vm_actor_retire, _, _, _}
    Actor.acknowledge(actor, [outcome.id])
    assert_receive {:vm_actor_retire, @id, ^actor, ^outcome}, 2000
    stop_supervised!(Actor)
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, nil}, 2000
    assert_receive {:vm_actor_retire, @id, ^replacement, ^outcome}, 2000
  end

  # @cc [owner:ghuntley,label:verification] delete-backoff-never-delays-new-intent
  # A cleanup-failed outcome MUST retain the deletion fence while suppressing an
  # immediate repeat. A newer command MUST be attempted without that old delay.
  test "cleanup failure delays the same delete but not a newer generation", context do
    deletion = command(2, :delete)
    {:ok, :stored} = accept(context, deletion)
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}, 2000
    Actor.reconcile(actor)
    assert_receive {:execute, task, ^deletion, _}, 2000

    send(task, {
      :result,
      {:ok,
       %{
         state: :unknown,
         compute_empty: false,
         disk_present: false,
         cleanup_complete: false,
         reason: :cleanup_failed
       }}
    })

    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :unknown}}, 2000
    Actor.reconcile(actor)
    refute_receive {:execute, _, _, _}, 100

    newer = command(3, :delete)
    {:ok, :stored} = accept(context, newer)
    Actor.reconcile(actor)
    assert_receive {:execute, _, ^newer, _}, 2000
  end

  # @cc [owner:ghuntley,label:verification;recovery] generated-delete-retry-plateau
  # Consecutive cleanup failures MUST retain delete intent and a nonterminal
  # outcome while the delay reaches and stays at thirty seconds. A newer
  # generation MUST be attempted immediately despite the old retry deadline.
  @tag :hegel
  test "generated cleanup failures plateau without retiring or delaying new intent", context do
    check all(failures <- integer(6..8), test_cases: 6) do
      directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      {:ok, store} = Store.open(directory, @id, 3)
      deletion = command(2, :delete)
      {:ok, :stored} = Store.accept(store, deletion)
      options = Keyword.put(context.options, :store, store)
      actor = start_supervised!({Actor, options})
      assert_receive {:vm_actor_ready, @id, ^actor, nil}, 2000

      for attempt <- 1..failures do
        if attempt > 1 do
          :sys.replace_state(actor, fn state ->
            %{state | next_delete_attempt_at: System.monotonic_time(:millisecond) - 1}
          end)
        end

        Actor.reconcile(actor)
        assert_receive {:execute, worker, ^deletion, _}, 2000
        before_result = System.monotonic_time(:millisecond)

        send(worker, {
          :result,
          {:ok,
           %{
             state: :unknown,
             compute_empty: false,
             disk_present: false,
             cleanup_complete: false,
             reason: :cleanup_failed
           }}
        })

        assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :unknown}}, 2000
        after_result = System.monotonic_time(:millisecond)
        state = :sys.get_state(actor)
        delay = Enum.at([1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000], attempt - 1)

        assert state.delete_attempts == attempt
        assert state.next_delete_attempt_at >= before_result + delay
        assert state.next_delete_attempt_at <= after_result + delay + 500
        assert {:ok, ^deletion} = Store.read(store, @id)
        refute_received {:vm_actor_retire, @id, ^actor, _}
      end

      newer = command(3, :delete)
      {:ok, :stored} = Store.accept(store, newer)
      Actor.reconcile(actor)
      assert_receive {:execute, worker, ^newer, _}, 2000
      assert :sys.get_state(actor).delete_attempts == 0
      send(worker, {:result, {:retry, :storage_busy}})
      stop_supervised!(Actor)
    end
  end

  test "resize interruption and actor restart retain source intent and applied-size proof",
       context do
    stopped = command(2, :stop)
    {:ok, :stored} = accept(context, stopped)

    resize =
      Map.merge(command(3, :resize), %{
        vcpu: 2,
        disk_bytes: 3_221_225_472,
        resize_from: OverallsProtocol.Resize.sizes(stopped),
        resize_id: Lilly.UUID.generate()
      })

    {:ok, :stored} = accept(context, resize)
    actor = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^actor, nil}
    Actor.reconcile(actor)
    assert_receive {:execute, task, ^resize, _}, 2000
    monitor = Process.monitor(task)
    stop_supervised!(Actor)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 2000
    replacement = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^replacement, nil}
    Actor.reconcile(replacement)
    assert_receive {:execute, resumed, ^resize, _}, 2000

    proof = %{
      state: :stopped,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none,
      applied_sizes: OverallsProtocol.Resize.sizes(resize)
    }

    send(resumed, {:result, {:ok, proof}})
    assert_receive {:vm_actor_outcome, @id, ^replacement, outcome}, 2000
    assert outcome.applied_sizes == proof.applied_sizes
    stop_supervised!(Actor)
    recovered = start_supervised!({Actor, context.options})
    assert_receive {:vm_actor_ready, @id, ^recovered, ^outcome}, 2000
    Actor.acknowledge(recovered, [Lilly.UUID.generate()])
    assert_receive {:vm_actor_outcome, @id, ^recovered, ^outcome}, 2000
  end

  defp running,
    do: %{
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

  defp command(generation, kind),
    do: %{
      id: Lilly.UUID.generate(),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: generation,
      kind: kind,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

  # @cc [owner:ghuntley,label:verification;recovery] actor-cadence-no-lost-request
  # A changed durable command during an in-flight, uncommitted observation
  # MUST preempt it and start exactly one follow-up observation at once, not
  # at the next tick, however many reconcile casts announced it (ADR-0176).
  test "a changed command during an uncommitted observation preempts it once", context do
    actor = start_supervised!({Actor, context.options})
    Actor.reconcile(actor)
    assert_receive {:execute, first, _, _}, 2000
    monitor = Process.monitor(first)
    stop = command(2, :stop)
    {:ok, :stored} = accept(context, stop)
    Actor.reconcile(actor)
    Actor.reconcile(actor)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 2000
    assert_receive {:execute, second, ^stop, _}, 300
    send(second, {:result, {:retry, :booting}})
    # The collapsed requests produced exactly one follow-up, not a backlog.
    refute_receive {:execute, _, _, _}, 300
  end

  # Stores a command and publishes it as durable intent, as the Runtime does.
  defp accept(context, command) do
    result = Store.accept(context.store, command)
    if match?({:ok, _}, result), do: :ok = Execution.intent(context.view, command)
    result
  end
end
