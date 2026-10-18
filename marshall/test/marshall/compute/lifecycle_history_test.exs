defmodule Marshall.Compute.LifecycleHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  import ExUnit.Assertions

  alias Marshall.Accounts.AdminEvent
  alias Marshall.{CommittedFixtureInventory, Repo}
  alias Marshall.Access
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    Ledger,
    LifecycleEvent,
    NetworkAddress,
    Operation,
    Outcomes,
    PhysicalOutcome,
    Reservation,
    StoragePool,
    VirtualMachine
  }

  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  require Marshall.CommittedFixtureCleanup

  # Generated histories over the real Ash lifecycle actions and the real
  # protocol physical-outcome ingestion path. The independent model computes
  # admission, refusal and every durable row expectation before the command
  # executes; it never reads the implementation's derivation.

  @type kind :: :start | :stop | :delete
  @type actor_choice :: :owner | :foreign | :manager
  @type op_back :: non_neg_integer()
  @type outcome_spec :: :normal | :unknown | :crash | :failure | :mismatched

  @type command ::
          {:request, kind(), :fresh | {:reuse, non_neg_integer()}, actor_choice()}
          | {:outcome, op_back(), outcome_spec()}
          | {:conflict, :replay | :payload | :sequence | :invalid}
          | {:host, :available | :unavailable}
          | {:access, :grant | :revoke}
          | :count_crashes

  @type op_model :: %{
          id: String.t() | nil,
          kind: :provision | kind(),
          generation: pos_integer(),
          status: :pending | :completed | :cancelled,
          initiator: :user | :recovery,
          key: String.t() | nil,
          requester: String.t() | nil
        }

  @type outcome_model :: %{
          id: String.t(),
          generation: pos_integer(),
          sequence: pos_integer(),
          wire: map()
        }

  @type event :: %{
          r: String.t(),
          a: String.t(),
          p: String.t() | nil,
          n: String.t() | nil,
          k: :user | :system,
          aid: String.t() | nil,
          g: pos_integer()
        }

  @type model :: %{
          vm_id: String.t(),
          desired: :running | :stopped | :deleted,
          observed: :pending | :running | :stopped | :deleted | :failed | :unknown,
          generation: pos_integer(),
          outcome_sequence: non_neg_integer(),
          failure_reason: atom() | nil,
          crash_attempts: non_neg_integer(),
          archived: boolean(),
          holds: {boolean(), boolean(), boolean(), boolean()},
          address: boolean(),
          operations: [op_model()],
          outcomes: [outcome_model()],
          sequence: non_neg_integer(),
          keys: %{{String.t(), String.t()} => kind()},
          access_role: :none | :manager,
          access_changes: [:manager | :revoked],
          host_available: boolean(),
          events: [event()]
        }

  @type ctx :: %{
          host_id: String.t(),
          vm_id: String.t(),
          users_before: [String.t()],
          owner: Marshall.Accounts.User.t(),
          foreign: Marshall.Accounts.User.t(),
          manager: Marshall.Accounts.User.t()
        }

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every journey MUST restore its complete pre-test row inventory, including
  # historical rows. ExUnit reports this independent teardown check separately
  # from a body failure; it MUST NOT replace the original assertion.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  @spec commands() :: Hegel.Gen.t(command())
  defp commands do
    one_of([
      tuple(
        {member_of([:start, :stop, :delete]),
         one_of([constant(:fresh), tuple({constant(:reuse), integer(0..3)})]),
         member_of([:owner, :foreign, :manager])}
      )
      |> map(fn {kind, key_choice, actor} -> {:request, kind, key_choice, actor} end),
      tuple(
        {constant(:outcome), integer(0..3),
         member_of([:normal, :unknown, :crash, :failure, :mismatched])}
      ),
      tuple({constant(:conflict), member_of([:replay, :payload, :sequence, :invalid])}),
      tuple({constant(:host), member_of([:available, :unavailable])}),
      tuple({constant(:access), member_of([:grant, :revoke])}),
      constant(:count_crashes)
    ])
  end

  # @cc [owner:ghuntley,label:verification] lifecycle-history-real-action-oracle
  # Generated command histories MUST drive the real public lifecycle actions
  # and the real protocol outcome ingestion path, and every committed prefix
  # MUST match the independently computed model: VM row, complete operation set
  # with provenance, per-placement reservation hold bits, address presence,
  # physical-outcome ledger and the complete durable lifecycle event chain.
  # Refusal expectations, including reason atoms, are computed by the model
  # before each command executes. Crash-recovery assertions MUST establish only
  # safe restart bounds; the dead-restart limit (three per ten minutes) is
  # crossed deterministically in the fixed arc before the generated middle.
  property "generated lifecycle histories preserve the durable transition model",
    test_cases: 100 do
    middle = draw("middle", list_of(commands(), min_length: 6, max_length: 24))

    late =
      draw(
        "late",
        list_of(tuple({integer(0..3), member_of([:normal, :unknown])}),
          min_length: 1,
          max_length: 4
        )
      )

    unboxed(fn ->
      fixture = host_fixture()
      owner = user()
      foreign = user()
      manager = user()

      Cleanup.protect do
        journey(fixture, owner, foreign, manager, middle, late)
      after
        cleanup(fixture.host.id, [owner.id, foreign.id, manager.id])
      end
    end)
  end

  @spec journey(
          map(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          [command()],
          [{non_neg_integer(), :normal | :unknown}]
        ) :: :ok
  defp journey(fixture, owner, foreign, manager, middle, late) do
    {:ok, vm} = Compute.provision(request(), actor: owner)

    # Retained historical fixture users belong to earlier suites. The oracle's
    # exact user-set expectation is the committed set at journey start (which
    # includes this journey's three actors); cleanup must restore exactly the
    # historical subset.
    %{rows: users_before} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM users", [], log: false)

    [provision] = Ledger.read!(Operation, vm_id: vm.id)

    ctx = %{
      host_id: fixture.host.id,
      vm_id: vm.id,
      users_before: Enum.sort(Enum.map(users_before, fn [id] -> id end)),
      owner: owner,
      foreign: foreign,
      manager: manager
    }

    assert [owner.id, foreign.id, manager.id] -- ctx.users_before == []

    # The provision operation carries no lifecycle request key; its idempotency
    # lives on the VM identity instead. Lifecycle keys are therefore tracked
    # only from the first accepted request onward.
    model = %{
      vm_id: vm.id,
      desired: :running,
      observed: :pending,
      generation: 1,
      outcome_sequence: 0,
      failure_reason: nil,
      crash_attempts: 0,
      archived: false,
      holds: {true, true, true, true},
      address: true,
      operations: [
        %{
          id: provision.id,
          kind: :provision,
          generation: 1,
          status: :pending,
          initiator: :user,
          key: nil,
          requester: owner.id
        }
      ],
      outcomes: [],
      sequence: 0,
      keys: %{},
      access_role: :none,
      access_changes: [],
      host_available: true,
      events: [
        %{
          r: "VirtualMachine",
          a: "allocate",
          p: nil,
          n: "running",
          k: :user,
          aid: owner.id,
          g: 1
        },
        %{r: "Operation", a: "enqueue", p: nil, n: "pending", k: :user, aid: owner.id, g: 1}
      ]
    }

    assert_model(model, ctx)

    # The fixed opening arc crosses stop, restart and a duplicate start intent,
    # then the bounded crash-recovery boundary: three restarts, exhaustion with
    # compute-only release, a stale running refusal under released compute, and
    # an explicit user restart that resets the crash budget. Interleaving this
    # boundary with every generated middle retains deterministic coverage no
    # matter what the generator emits.
    opening = [
      {:request, :stop, :fresh, :owner},
      {:outcome, 0, :normal},
      {:request, :start, :fresh, :owner},
      {:outcome, 0, :normal},
      {:request, :start, :fresh, :owner},
      {:outcome, 0, :normal},
      {:outcome, 0, :crash},
      {:outcome, 0, :crash},
      {:outcome, 0, :crash},
      {:outcome, 0, :crash},
      :count_crashes,
      {:outcome, 0, :normal},
      {:request, :start, :fresh, :owner},
      {:outcome, 0, :normal}
    ]

    # The fixed closing arc deletes through an unconfirmed effect: intent is
    # committed, the physical result is first unknown (every hold retained) and
    # only the confirmed deletion releases storage, address and identity.
    closing = [
      {:request, :delete, :fresh, :owner},
      {:outcome, 0, :unknown},
      {:outcome, 0, :normal}
    ]

    model = run_history(opening ++ middle ++ closing, model, ctx)
    assert model.archived

    # Delayed receipts for archived VMs remain durable evidence without
    # restoring VM state or released capacity.
    archived_tail = Enum.map(late, fn {back, kind} -> {:outcome, back, kind} end)
    model = run_history(archived_tail ++ [{:conflict, :payload}], model, ctx)

    assert model.archived
    assert model.observed == :deleted
    assert model.holds == {false, false, false, false}

    # Terminal authority probes: every fresh intent is refused and every exact
    # delete replay (if the owner ever issued one) returns its retained
    # operation without changing any row.
    prove_refusal(ctx, ctx.owner, :start, Ash.UUID.generate(), "vm_deleted")

    manager_reason = if model.access_role == :manager, do: "vm_deleted", else: "forbidden"
    prove_refusal(ctx, ctx.manager, :start, Ash.UUID.generate(), manager_reason)
    prove_refusal(ctx, ctx.foreign, :stop, Ash.UUID.generate(), "forbidden")

    case Enum.find(model.keys, fn {{requester, _key}, kind} ->
           requester == ctx.owner.id and kind == :delete
         end) do
      nil ->
        :ok

      {{_requester, delete_key}, :delete} ->
        assert {:ok, replayed} =
                 Compute.lifecycle(
                   %{vm_id: ctx.vm_id, kind: :delete, idempotency_key: delete_key},
                   actor: ctx.owner
                 )

        final_op = List.last(model.operations)
        assert final_op.kind == :delete
        assert replayed.id == final_op.id
        assert_model(model, ctx)
        prove_refusal(ctx, ctx.owner, :stop, delete_key, "idempotency_conflict")
    end

    assert_model(model, ctx)
    :ok
  end

  @spec run_history([command()], model(), ctx()) :: model()
  defp run_history(commands, model, ctx) do
    Enum.reduce(commands, model, fn command, model ->
      run_assert(fn ->
        model = step(command, model, ctx)
        assert_model(model, ctx)
        model
      end)
    end)
  end

  @spec prove_refusal(ctx(), Marshall.Accounts.User.t(), kind(), String.t(), String.t()) :: :ok
  defp prove_refusal(ctx, actor, kind, key, reason) do
    assert {:error, error} =
             Compute.lifecycle(%{vm_id: ctx.vm_id, kind: kind, idempotency_key: key},
               actor: actor
             )

    assert Exception.message(error) =~ reason
    :ok
  end

  @spec run_assert((-> model())) :: model()
  defp run_assert(body) do
    body.()
  rescue
    error ->
      flunk("lifecycle history step diverged from the model: #{Exception.message(error)}")
  end

  # @cc [owner:ghuntley,label:verification] lifecycle-history-model-step
  # Every step MUST compute its admission/refusal expectation from the model
  # alone before touching the database, and MUST return the updated model only
  # after the real action matches that expectation. Availability changes keep
  # their abstract state until an explicit host command flips them; accepting
  # caller steps maintain the corresponding fresh physical reports so durability
  # expectations never depend on wall-clock drift.
  @spec step(command(), model(), ctx()) :: model()

  defp step({:request, kind, key_choice, actor_choice}, model, ctx) do
    {actor, aid} = actor_of(ctx, actor_choice)
    used = used_keys(model, aid)
    key = request_key(key_choice, used)

    authorized? =
      actor_choice == :owner or (actor_choice == :manager and model.access_role == :manager)

    expected = expected_request(model, kind, key, aid, authorized?)
    if kind == :start, do: maintain_freshness(ctx, model)

    result =
      Compute.lifecycle(%{vm_id: ctx.vm_id, kind: kind, idempotency_key: key}, actor: actor)

    case expected do
      {:refused, reason} ->
        assert {:error, error} = result
        assert Exception.message(error) =~ Atom.to_string(reason)
        model

      {:replay, existing_id} ->
        assert {:ok, operation} = result
        assert operation.id == existing_id
        model

      :accepted ->
        assert {:ok, operation} = result
        accept_request(model, ctx, kind, key, aid, operation)
    end
  end

  defp step({:outcome, back, kind_spec}, model, ctx) do
    target = Enum.at(Enum.reverse(model.operations), min(back, length(model.operations) - 1))
    {state, reason} = outcome_shape(kind_spec, target.kind)

    case expected_outcome(model, target, state) do
      {:refused, refusals} ->
        {result, _event, _wire} = deliver(ctx, target, state, reason, model.sequence + 1)
        assert result in refusals
        model

      :applied ->
        if reason == :crashed, do: maintain_freshness(ctx, model)
        sequence = model.sequence + 1
        {result, _event, wire} = deliver(ctx, target, state, reason, sequence)
        assert {:ok, [id]} = result
        apply_outcome(model, target, state, reason, id, wire, sequence)

      :recorded ->
        sequence = model.sequence + 1
        {result, _event, wire} = deliver(ctx, target, state, reason, sequence)
        assert {:ok, [id]} = result
        record_outcome(model, target, id, wire, sequence)
    end
  end

  defp step({:conflict, which}, model, ctx) do
    # A prior issued outcome identity/sequence is never reusable: identical
    # replay deduplicates, a changed payload or reused sequence rolls back, and
    # an incoherent wire shape fails at the protocol codec before any durable
    # write. The opening arc guarantees at least one issued outcome.
    previous = List.last(model.outcomes)

    case which do
      :replay ->
        assert {:ok, [previous_id]} = deliver_encoded(ctx, previous.wire)
        assert previous_id == previous.id
        :ok

      :payload ->
        changed = Map.put(previous.wire, "sequence", previous.wire["sequence"] + 10_000)
        assert {:error, :outcome_conflict} = deliver_encoded(ctx, changed)
        :ok

      :sequence ->
        current = List.last(model.operations)
        {event, _wire} = outcome_event(ctx, current, :unknown, :unknown, previous.sequence)
        assert {:error, :outcome_conflict} = deliver_decoded(ctx, event)
        :ok

      :invalid ->
        wire =
          Map.merge(previous.wire, %{
            "id" => Ash.UUID.generate(),
            "state" => "running",
            "compute_empty" => true
          })

        assert {:error, :invalid_message} = deliver_encoded(ctx, wire)
        :ok
    end

    model
  end

  defp step({:host, availability}, model, ctx) do
    reported_at =
      case availability do
        :available -> Ledger.now()
        # Beyond the five-second freshness window, unconditionally stale.
        :unavailable -> DateTime.add(Ledger.now(), -10, :second)
      end

    [host] = Ledger.read!(Host, id: ctx.host_id)
    Ledger.update!(host, :report, %{reported_at: reported_at})
    %{model | host_available: availability == :available}
  end

  defp step({:access, role}, model, ctx) do
    request = %{
      vm_id: ctx.vm_id,
      email: to_string(ctx.manager.email),
      role: if(role == :grant, do: :manager, else: :revoked),
      idempotency_key: Ash.UUID.generate()
    }

    expected =
      cond do
        model.archived -> {:refused, "forbidden"}
        model.desired == :deleted -> {:refused, "vm_deleted"}
        true -> :accepted
      end

    result = Access.set_access(request, actor: ctx.owner)

    case expected do
      {:refused, reason} ->
        assert {:error, error} = result
        assert Exception.message(error) =~ reason
        model

      :accepted ->
        assert {:ok, _change} = result

        %{
          model
          | access_role: if(role == :grant, do: :manager, else: :none),
            access_changes: model.access_changes ++ [request.role]
        }
    end
  end

  defp step(:count_crashes, model, _ctx) do
    # The physical restart budget is three attempts in ten minutes; the model
    # can never exceed it because every restart is a durable generation bump.
    assert model.crash_attempts <= 3
    model
  end

  # Keep the abstract availability state and the physical freshness facts in
  # lockstep: an available host reports fresh capacity/pool timestamps; an
  # unavailable one stays stale until an explicit host command flips it.
  @spec maintain_freshness(ctx(), model()) :: :ok
  defp maintain_freshness(_ctx, %{host_available: false}), do: :ok

  defp maintain_freshness(ctx, %{host_available: true}) do
    now = Ledger.now()
    [host] = Ledger.read!(Host, id: ctx.host_id)
    Ledger.update!(host, :report, %{reported_at: now})
    [reservation] = Ledger.read!(Reservation, vm_id: ctx.vm_id)
    [pool] = Ledger.read!(StoragePool, id: reservation.pool_id)
    Ledger.update!(pool, :report, %{reported_at: now})
    :ok
  end

  @spec actor_of(ctx(), actor_choice()) :: {Marshall.Accounts.User.t(), String.t()}
  defp actor_of(ctx, :owner), do: {ctx.owner, ctx.owner.id}
  defp actor_of(ctx, :foreign), do: {ctx.foreign, ctx.foreign.id}
  defp actor_of(ctx, :manager), do: {ctx.manager, ctx.manager.id}

  @spec used_keys(model(), String.t()) :: [String.t()]
  defp used_keys(model, aid) do
    for {{requester, key}, _kind} <- model.keys, requester == aid, do: key
  end

  @spec request_key(:fresh | {:reuse, non_neg_integer()}, [String.t()]) :: String.t()
  defp request_key(:fresh, _used), do: Ash.UUID.generate()

  defp request_key({:reuse, index}, used) do
    case used do
      [] -> Ash.UUID.generate()
      _ -> Enum.at(Enum.sort(used), rem(index, length(used)))
    end
  end

  @spec expected_request(model(), kind(), String.t(), String.t(), boolean()) ::
          :accepted | {:replay, String.t()} | {:refused, atom()}
  defp expected_request(model, kind, key, aid, authorized?) do
    cond do
      not authorized? ->
        {:refused, :forbidden}

      Map.has_key?(model.keys, {aid, key}) ->
        if model.keys[{aid, key}] == kind do
          [operation] =
            for op <- model.operations,
                op.requester == aid and op.key == key,
                do: op

          {:replay, operation.id}
        else
          {:refused, :idempotency_conflict}
        end

      model.archived or model.desired == :deleted ->
        {:refused, :vm_deleted}

      kind == :start and not model.host_available ->
        {:refused, :host_unavailable}

      true ->
        :accepted
    end
  end

  @spec accept_request(model(), ctx(), kind(), String.t(), String.t(), Operation.t()) :: model()
  defp accept_request(model, ctx, kind, key, aid, operation) do
    desired = %{start: :running, stop: :stopped, delete: :deleted}[kind]
    {_compute, disk, _startup_compute, startup_disk} = model.holds
    holds = if kind == :start, do: {true, disk, true, startup_disk}, else: model.holds
    generation = model.generation + 1

    cancelled =
      for op <- model.operations, op.status == :pending do
        %{
          r: "Operation",
          a: "cancel",
          p: "pending",
          n: "cancelled",
          k: :user,
          aid: aid,
          g: op.generation
        }
      end

    request_action =
      %{start: "request_start", stop: "request_stop", delete: "request_delete"}[kind]

    events =
      model.events ++
        cancelled ++
        [
          %{
            r: "VirtualMachine",
            a: request_action,
            p: Atom.to_string(model.desired),
            n: Atom.to_string(desired),
            k: :user,
            aid: aid,
            g: generation
          },
          %{
            r: "Operation",
            a: "enqueue",
            p: nil,
            n: "pending",
            k: :user,
            aid: aid,
            g: generation
          }
        ]

    operations =
      Enum.map(model.operations, fn op ->
        if op.status == :pending, do: %{op | status: :cancelled}, else: op
      end) ++
        [
          %{
            id: operation.id,
            kind: kind,
            generation: generation,
            status: :pending,
            initiator: :user,
            key: key,
            requester: aid
          }
        ]

    assert operation.kind == kind
    assert operation.generation == generation
    assert operation.request_key == key
    assert operation.requested_by_id == aid
    assert operation.vm_id == ctx.vm_id
    assert operation.initiator == :user

    %{
      model
      | desired: desired,
        generation: generation,
        crash_attempts: 0,
        holds: holds,
        operations: operations,
        keys: Map.put(model.keys, {aid, key}, kind),
        events: events
    }
  end

  @spec outcome_shape(outcome_spec(), atom()) ::
          {:running | :stopped | :deleted | :failed | :unknown, atom()}
  defp outcome_shape(:normal, kind) when kind in [:provision, :start], do: {:running, :none}
  defp outcome_shape(:normal, :stop), do: {:stopped, :none}
  defp outcome_shape(:normal, :delete), do: {:deleted, :none}
  defp outcome_shape(:unknown, _kind), do: {:unknown, :unknown}
  defp outcome_shape(:crash, _kind), do: {:failed, :crashed}
  defp outcome_shape(:failure, _kind), do: {:failed, :execution_failed}

  defp outcome_shape(:mismatched, kind) when kind in [:provision, :start], do: {:stopped, :none}
  defp outcome_shape(:mismatched, :stop), do: {:running, :none}
  defp outcome_shape(:mismatched, :delete), do: {:running, :none}

  @spec compatible?(atom(), atom()) :: boolean()
  defp compatible?(kind, state) when kind in [:provision, :start],
    do: state in [:running, :failed, :unknown]

  defp compatible?(:stop, state), do: state in [:stopped, :unknown]
  defp compatible?(:delete, state), do: state in [:deleted, :unknown]

  @spec expected_outcome(model(), op_model(), atom()) ::
          :applied | :recorded | {:refused, [atom()]}

  # @cc [owner:ghuntley,label:verification] lifecycle-history-outcome-admission
  # Outcome admission MUST be predicted from the durable rules alone: kind/state
  # incompatibility is refused; stale generations and archived VMs are recorded
  # without effect; a running observation without retained compute is a conflict;
  # only a fresh sequence on the current generation applies its documented
  # effect.
  defp expected_outcome(model, target, state) do
    cond do
      not compatible?(target.kind, state) ->
        {:refused, [{:error, :invalid_outcome}]}

      model.archived or target.generation != model.generation ->
        :recorded

      state == :running and not elem(model.holds, 0) ->
        {:refused, [{:error, :outcome_conflict}]}

      true ->
        :applied
    end
  end

  @spec record_outcome(model(), op_model(), String.t(), map(), pos_integer()) :: model()
  defp record_outcome(model, target, id, wire, sequence) do
    %{
      model
      | sequence: sequence,
        outcomes:
          model.outcomes ++
            [%{id: id, generation: target.generation, sequence: sequence, wire: wire}]
    }
  end

  # @cc [owner:ghuntley,label:verification] lifecycle-history-outcome-model
  # Applied outcomes MUST follow the documented effects independently of the
  # implementation: confirmed running/stopped/delete completion rules, retained
  # holds on unknown effects, bounded crash recovery only while compute is
  # retained and the host reports fresh capacity, and compute-only release on
  # failure or exhaustion with disk and address retained. A completed operation
  # MUST NOT emit a second completion event.
  @spec apply_outcome(model(), op_model(), atom(), atom(), String.t(), map(), pos_integer()) ::
          model()
  defp apply_outcome(model, target, state, reason, id, wire, sequence) do
    model = record_outcome(model, target, id, wire, sequence)

    failure_reason =
      case state do
        s when s in [:running, :stopped, :deleted] -> nil
        :failed -> reason
        :unknown -> :unknown
      end

    base = %{
      model
      | observed: state,
        outcome_sequence: sequence,
        failure_reason: failure_reason,
        events:
          model.events ++
            [
              %{
                r: "VirtualMachine",
                a: "observe",
                p: Atom.to_string(model.observed),
                n: Atom.to_string(state),
                k: :system,
                aid: nil,
                g: model.generation
              }
            ]
    }

    complete_event = fn events, ops ->
      if Enum.find(ops, &(&1.id == target.id)).status == :completed do
        events
      else
        events ++
          [
            %{
              r: "Operation",
              a: "complete",
              p: "pending",
              n: "completed",
              k: :system,
              aid: nil,
              g: target.generation
            }
          ]
      end
    end

    mark_completed = fn ops ->
      Enum.map(ops, fn op -> if op.id == target.id, do: %{op | status: :completed}, else: op end)
    end

    case {base.desired, target.kind, state} do
      {:running, kind, :running} when kind in [:provision, :start] ->
        %{
          base
          | operations: mark_completed.(base.operations),
            events: complete_event.(base.events, base.operations)
        }

      {:stopped, :stop, :stopped} ->
        {compute, disk, _startup_compute, startup_disk} = base.holds
        _ = compute

        %{
          base
          | operations: mark_completed.(base.operations),
            events: complete_event.(base.events, base.operations),
            holds: {false, disk, false, startup_disk}
        }

      {:deleted, :delete, :deleted} ->
        %{
          base
          | operations: mark_completed.(base.operations),
            holds: {false, false, false, false},
            address: false,
            archived: true,
            events:
              complete_event.(base.events, base.operations) ++
                [
                  %{
                    r: "VirtualMachine",
                    a: "archive",
                    p: "deleted",
                    n: "deleted",
                    k: :system,
                    aid: nil,
                    g: base.generation
                  }
                ]
        }

      {:running, kind, :failed} when kind in [:provision, :start] ->
        {compute, disk, _startup_compute, startup_disk} = base.holds

        if reason == :crashed and compute and model.host_available and base.crash_attempts < 3 do
          generation = base.generation + 1

          events =
            complete_event.(base.events, base.operations) ++
              [
                %{
                  r: "VirtualMachine",
                  a: "request_start",
                  p: Atom.to_string(base.desired),
                  n: "running",
                  k: :system,
                  aid: nil,
                  g: generation
                },
                %{
                  r: "Operation",
                  a: "enqueue",
                  p: nil,
                  n: "pending",
                  k: :system,
                  aid: nil,
                  g: generation
                }
              ]

          %{
            base
            | operations:
                mark_completed.(base.operations) ++
                  [
                    %{
                      id: nil,
                      kind: :start,
                      generation: generation,
                      status: :pending,
                      initiator: :recovery,
                      key: nil,
                      requester: nil
                    }
                  ],
              generation: generation,
              crash_attempts: base.crash_attempts + 1,
              events: events
          }
          |> fill_recovery_id()
        else
          # A crash while the host's report is merely stale (not a measured
          # shortfall) keeps every hold and awaits the next accepted report
          # (ADR-0140); an exhausted budget or no compute releases it.
          if reason == :crashed and compute and base.crash_attempts < 3 do
            %{
              base
              | operations: mark_completed.(base.operations),
                events: complete_event.(base.events, base.operations)
            }
          else
            %{
              base
              | operations: mark_completed.(base.operations),
                events: complete_event.(base.events, base.operations),
                holds: {false, disk, false, startup_disk}
            }
          end
        end

      _ ->
        base
    end
  end

  # The recovery path appends the operation inside the same transaction; its
  # real id is read back from the durable operation set by generation.
  @spec fill_recovery_id(model()) :: model()
  defp fill_recovery_id(model) do
    generation = model.generation
    [%{id: id}] = Ledger.read!(Operation, vm_id: model.vm_id, generation: generation)

    %{
      model
      | operations:
          Enum.map(model.operations, fn op ->
            if op.generation == generation and is_nil(op.id), do: %{op | id: id}, else: op
          end)
    }
  end

  @spec outcome_event(ctx(), op_model(), atom(), atom(), pos_integer()) :: {map(), map()}
  defp outcome_event(ctx, operation, state, reason, sequence) do
    [row] = Ledger.read!(Operation, id: operation.id)

    event = %{
      id: Ash.UUID.generate(),
      vm_id: ctx.vm_id,
      placement_id: row.placement_id,
      execution_epoch: row.execution_epoch,
      operation_id: row.id,
      generation: row.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:stopped, :deleted, :failed],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: reason
    }

    {event, OverallsProtocol.Execution.encode_outcome(event)}
  end

  @spec deliver(ctx(), op_model(), atom(), atom(), pos_integer()) ::
          {{:ok, [String.t()]} | {:error, atom()}, map(), map()}
  defp deliver(ctx, operation, state, reason, sequence) do
    {event, wire} = outcome_event(ctx, operation, state, reason, sequence)
    {deliver_decoded(ctx, event), event, wire}
  end

  @spec deliver_decoded(ctx(), map()) :: {:ok, [String.t()]} | {:error, atom()}
  defp deliver_decoded(ctx, event) do
    {:ok, decoded} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, ctx.host_id)
      Outcomes.ingest_locked!(ctx.host_id, [decoded])
    end)
  end

  @spec deliver_encoded(ctx(), map()) :: {:ok, [String.t()]} | {:error, atom()}
  defp deliver_encoded(ctx, wire) do
    case OverallsProtocol.Execution.outcome(wire) do
      {:ok, decoded} ->
        Ledger.transaction(fn ->
          Ledger.lock!(Host, ctx.host_id)
          Outcomes.ingest_locked!(ctx.host_id, [decoded])
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # @cc [owner:ghuntley,label:verification] lifecycle-history-complete-row-oracle
  # Every step MUST re-verify the complete committed projection for the subject
  # VM directly from PostgreSQL: VM intent/observation/archival fields, the
  # complete operation set with requester provenance and pinned completion
  # evidence, reservation hold bits, address presence, immutable physical
  # outcome bytes, lifecycle events, users and access grants. Unrelated
  # committed fixture rows are covered separately by the whole-suite inventory
  # restoration assertion.
  @spec assert_model(model(), ctx()) :: :ok
  defp assert_model(model, ctx) do
    [vm] = Ledger.history!(VirtualMachine, id: ctx.vm_id)

    assert {vm.desired_state, vm.observed_state, vm.generation, vm.outcome_sequence,
            vm.failure_reason, length(vm.crash_restart_times), vm.archived_at != nil} ==
             {model.desired, model.observed, model.generation, model.outcome_sequence,
              model.failure_reason, model.crash_attempts, model.archived}

    assert Ledger.read!(VirtualMachine, id: ctx.vm_id) == if(model.archived, do: [], else: [vm])

    operations =
      Ledger.read!(Operation, vm_id: ctx.vm_id) |> Enum.sort_by(&{&1.generation, &1.id})

    assert Enum.map(
             operations,
             &{&1.kind, &1.generation, &1.status, &1.initiator, &1.requested_by_id,
              &1.request_key}
           ) ==
             Enum.map(
               model.operations,
               &{&1.kind, &1.generation, &1.status, &1.initiator, &1.requester, &1.key}
             )

    assert Enum.count(operations, &(&1.status == :pending)) <= 1

    # Completion pins its immutable physical evidence on the same generation.
    for operation <- operations, operation.status == :completed do
      assert operation.completion_outcome_id != nil
      [evidence] = Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id)
      assert evidence.generation == operation.generation
      assert Enum.any?(model.outcomes, &(&1.id == evidence.id))
    end

    [reservation] = Ledger.read!(Reservation, vm_id: ctx.vm_id)

    assert {reservation.compute_held, reservation.disk_held, reservation.startup_compute_held,
            reservation.startup_disk_held} == model.holds

    assert length(Ledger.read!(NetworkAddress, vm_id: ctx.vm_id)) ==
             if(model.address, do: 1, else: 0)

    outcomes = Ledger.read!(PhysicalOutcome, vm_id: ctx.vm_id)

    assert Enum.sort(Enum.map(outcomes, &{&1.id, &1.generation, &1.sequence})) ==
             Enum.sort(Enum.map(model.outcomes, &{&1.id, &1.generation, &1.sequence}))

    for outcome <- outcomes do
      [expected] = Enum.filter(model.outcomes, &(&1.id == outcome.id))
      assert outcome.observation == expected.wire
    end

    events = Ledger.read!(LifecycleEvent, vm_id: ctx.vm_id)

    actual =
      Enum.map(events, fn event ->
        {event.resource_type, event.action, event.previous_state, event.next_state,
         event.actor_kind, event.actor_id, event.generation}
      end)

    expected =
      Enum.map(model.events, fn event ->
        {event.r, event.a, event.p, event.n, event.k, event.aid, event.g}
      end)

    assert Enum.sort(actual) == Enum.sort(expected)

    # Each resource's durable event chain must retrace its own state history;
    # VM intent (desired) and observation (observed) are independent streams.
    for {{resource, key, stream}, chain} <-
          Enum.group_by(events, fn event ->
            stream = if event.action == "observe", do: :observed, else: :intent
            {event.resource_type, event.resource_id, stream}
          end) do
      _ = {resource, key, stream}
      # DateTime structs do not sort chronologically under term ordering; the
      # chain order follows wall-clock time.
      ordered = Enum.sort_by(chain, &{DateTime.to_unix(&1.occurred_at, :microsecond), &1.id})

      Enum.reduce(ordered, :start, fn event, previous ->
        if previous != :start do
          assert event.previous_state == previous,
                 "chain break in #{inspect({resource, key, stream})}: " <>
                   inspect(
                     Enum.map(
                       ordered,
                       &{&1.action, &1.previous_state, &1.next_state, &1.generation}
                     )
                   )
        end

        event.next_state
      end)
    end

    %{rows: user_rows} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM users", [], log: false)

    assert Enum.sort(Enum.map(user_rows, fn [id] -> id end)) == ctx.users_before

    grants = Ledger.read!(Access.Grant, vm_id: ctx.vm_id)

    case model.access_role do
      :none ->
        assert grants == []

      :manager ->
        assert [%{user_id: user_id, role: :manager}] = grants
        assert user_id == ctx.manager.id
    end

    changes = Ledger.read!(Access.Change, vm_id: ctx.vm_id)
    assert changes |> Enum.map(& &1.role) |> Enum.sort() == Enum.sort(model.access_changes)

    assert Ledger.read!(AdminEvent, target_id: ctx.vm_id) == []
    :ok
  end

  @spec cleanup(String.t(), [String.t()]) :: :ok
  defp cleanup(host_id, user_ids) do
    Enum.find_value(user_ids, fn user_id ->
      cleanup_result = Cleanup.cleanup_compute(host_id, user_id)
      assert {:ok, _} = cleanup_result
      cleanup_result
    end)

    for user_id <- user_ids do
      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM users WHERE id = $1",
        [Ecto.UUID.dump!(user_id)],
        log: false
      )
    end

    :ok
  end

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(body), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, body)
end
