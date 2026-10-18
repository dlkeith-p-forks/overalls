defmodule Lilly.VM.CheckpointTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, Pool, PrivateFiles}
  alias Lilly.Lifecycle.Journal
  alias Lilly.Lifecycle.Checkpoint, as: Machine
  alias Lilly.VM.{Boot, Checkpoint, CheckpointStorage, Intent, Spec}
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @hash "sha256:" <> String.duplicate("a", 64)

  # @cc [owner:ghuntley,label:verification;recovery] checkpoint-single-use-restart-model
  # Actual Ash journal writes/reopens MUST preserve completion and single-use
  # authority. Generated later generations MUST NOT replay consumed memory.
  # This test proves BEAM journal rules only, never KVM or native ZFS behavior.
  property "reopened checkpoint history cannot skip copy proof or replay a restore",
    test_cases: 40 do
    generation = Hegel.draw("restore generation", integer(3..1_000_000))
    root = Path.join(System.tmp_dir!(), "checkpoint-model-" <> Lilly.UUID.generate())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {pool, spec} = fixture(root)
      states = states(pool, spec, generation)
      assert :ok = Journal.write(Machine, root, "checkpoint.json", states.empty)
      assert :ok = Journal.write(Machine, root, "checkpoint.json", states.capturing)
      assert {:error, _} = Journal.write(Machine, root, "checkpoint.json", states.ready)

      for state <- [states.copied, states.ready, states.restoring, states.consumed] do
        assert :ok = Journal.write(Machine, root, "checkpoint.json", state)
        assert {:ok, reopened} = Journal.load(Machine, root, "checkpoint.json")
        assert reopened.payload == state
      end

      original = File.read!(Path.join(root, "checkpoint.json"))

      for rejected <- [
            states.ready,
            states.restoring,
            put_in(states.consumed, ["restore_authority", "generation"], generation + 1),
            put_in(
              states.consumed,
              ["descriptor", "memory_sha256"],
              "sha256:" <> String.duplicate("c", 64)
            ),
            put_in(states.consumed, ["slots", "a", "dataset_guid"], "99"),
            put_in(states.consumed, ["slots", "a", "nonce"], String.duplicate("d", 32))
          ] do
        result = Journal.write(Machine, root, "checkpoint.json", rejected)
        assert match?({:error, _}, result)
      end

      assert File.read!(Path.join(root, "checkpoint.json")) == original

      assert :ok =
               Journal.write(Machine, root, "checkpoint.json", %{
                 states.consumed
                 | "phase" => "retired"
               })

      assert :ok = Journal.write(Machine, root, "checkpoint.json", Checkpoint.initial(pool, spec))
    after
      Lock.release(lock)
      File.rm_rf!(root)
    end
  end

  property "malformed private bindings and checkpoint slot identities fail closed" do
    {pool, spec} = fixture("/fixture")
    record = states(pool, spec, 3).ready
    bad = Hegel.draw("invalid authority", member_of([nil, -1, 0, "1", 1.0]))
    refute Checkpoint.valid_record?(put_in(record, ["capture_authority", "generation"], bad))
    refute Checkpoint.valid_record?(put_in(record, ["slots", "a", "dataset_guid"], bad))
    refute Checkpoint.valid_record?(Map.put(record, "path", "/untrusted"))

    refute Checkpoint.valid_record?(
             Map.put(%{record | "phase" => "retired"}, "checkpoint_id", "bad")
           )

    refute Checkpoint.valid_record?(
             Map.put(%{record | "phase" => "retired"}, "restore_authority", %{})
           )
  end

  # @cc [owner:ghuntley,label:verification;recovery] interrupted-capture-terminal-discard-model
  # Reopened capturing journals MUST permit only local terminal cleanup under
  # current or later authority, never RAM readiness, phase promotion or cold
  # execution. Stale, foreign, missing and executable authorities MUST refuse.
  property "terminal cleanup cannot promote an interrupted capture into usable RAM", %{
    tmp_dir: directory
  } do
    generation = draw("capture generation", integer(2..1_000_000))
    terminal_state = draw("terminal state", member_of([:stopped, :deleted, :failed]))
    root = Path.join(directory, Lilly.UUID.generate())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {pool, spec} = fixture(root)
      empty = states(pool, spec, generation + 1).empty
      authority = %{"placement_id" => spec.id, "execution_epoch" => 1, "generation" => generation}
      capturing = states(pool, spec, generation + 1).capturing

      capturing = %{
        capturing
        | "capture_authority" => authority,
          "manifest" => %{capturing["manifest"] | "source_authority" => authority}
      }

      assert :ok = Checkpoint.write(pool, spec.id, empty)
      assert :ok = Checkpoint.write(pool, spec.id, capturing)
      assert {:ok, ^capturing} = Checkpoint.read(pool, spec.id)
      intent_directory = Path.join(root, "intent")
      :ok = PrivateFiles.directory(intent_directory)
      assert {:ok, paused} = Intent.set(intent_directory, spec.id, {1, generation}, :paused)
      refute Checkpoint.discardable_pause?(capturing, pool, spec, paused)

      terminal_generation = if terminal_state == :failed, do: generation, else: generation + 1

      assert {:ok, terminal} =
               Intent.set(intent_directory, spec.id, {1, terminal_generation}, terminal_state)

      assert {:ok, ^terminal} = Intent.read(intent_directory)
      assert Checkpoint.discardable_pause?(capturing, pool, spec, terminal)
      assert {:error, :checkpoint_unconfirmed} = Checkpoint.ready(pool, spec)
      assert {:ok, ^capturing} = Checkpoint.read(pool, spec.id)

      for rejected <- [
            %{terminal | generation: generation - 1},
            %{terminal | execution_epoch: 0},
            %{terminal | placement_id: @other},
            %{terminal | state: :running},
            %{terminal | state: :paused}
          ] do
        refute Checkpoint.discardable_pause?(capturing, pool, spec, rejected)
      end

      for invalid <- [
            nil,
            %{},
            Map.put(capturing, "phase", "ready"),
            put_in(capturing, ["binding", "host_id"], @other)
          ] do
        refute Checkpoint.discardable_pause?(invalid, pool, spec, terminal)
      end
    after
      assert :ok = Lock.release(lock)
      File.rm_rf!(root)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery;concurrency] acknowledged-capture-survives-pool-contention
  # A real native pool lease held elsewhere MUST NOT prevent the acknowledged
  # copy's private journal transition under its configured placement lease;
  # an unrelated held native lease MUST refuse without advancing the journal.
  # Reopening MUST retain copied, unchanged native ownership and no ready RAM descriptor.
  # This exercises journal/lease integration, not a native Firecracker snapshot.
  property "pool contention cannot discard an acknowledged capture result", %{
    tmp_dir: directory
  } do
    generation = draw("capture generation", integer(2..1_000_000))
    epoch = draw("capture epoch", integer(1..1_000_000))
    root = Path.join(directory, Lilly.UUID.generate())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {pool, spec} = fixture(root)
    placement_directory = Path.join([root, "state", spec.id, "lock"])
    File.mkdir_p!(Path.dirname(placement_directory))
    {:ok, placement} = Lock.acquire(placement_directory)
    pool_directory = Path.join(root, ".lilly-storage")
    parent = self()
    ready = make_ref()

    holder =
      Task.async(fn ->
        {:ok, lease} = Lock.acquire(pool_directory)
        send(parent, {:pool_owned, ready})

        receive do
          {:release_pool, ^ready} -> :ok = Lock.release(lease)
        end
      end)

    try do
      assert_receive {:pool_owned, ^ready}, 5000
      assert {:error, :host_already_owned} = Lock.acquire(pool_directory)
      assert Lock.current() == placement
      history = states(pool, spec, generation + 1)

      authority = %{
        "placement_id" => spec.id,
        "execution_epoch" => epoch,
        "generation" => generation
      }

      capturing = %{
        history.capturing
        | "capture_authority" => authority,
          "manifest" => %{history.capturing["manifest"] | "source_authority" => authority}
      }

      assert :ok = Checkpoint.write(pool, spec.id, history.empty)
      assert :ok = Checkpoint.write(pool, spec.id, capturing)

      assert {:error, :checkpoint_unconfirmed} =
               Checkpoint.copied(
                 pool,
                 spec,
                 %{authority | "generation" => generation + 1},
                 placement_directory
               )

      assert {:error, :checkpoint_unconfirmed} =
               Checkpoint.copied(%{pool | id: @other}, spec, authority, placement_directory)

      assert {:ok, wrong_lease} = Lock.acquire(Path.join(root, "wrong-lock"))

      try do
        assert Lock.current() == wrong_lease
        assert Lock.held?(wrong_lease)

        assert {:error, :checkpoint_unconfirmed} =
                 Checkpoint.copied(pool, spec, authority, placement_directory)

        assert {:ok, ^capturing} = Checkpoint.read(pool, spec.id)
      after
        assert :ok = Lock.release(wrong_lease)
      end

      assert {:ok, ^capturing} = Checkpoint.read(pool, spec.id)
      assert Lock.current() == placement
      assert :ok = Checkpoint.copied(pool, spec, authority, placement_directory)
      assert {:ok, copied} = Checkpoint.read(pool, spec.id)
      assert copied["phase"] == "copied"
      assert copied["capture_authority"] == authority
      assert copied["descriptor"] == nil
      assert copied["slots"]["a"]["state"] == "empty"
      assert copied["slots"]["a"]["dataset_guid"] == capturing["slots"]["a"]["dataset_guid"]
      assert copied["slots"]["a"]["snapshot_guid"] == nil
      assert copied["slots"]["a"]["checkpoint_id"] == copied["checkpoint_id"]
      assert {:error, :checkpoint_unconfirmed} = Checkpoint.ready(pool, spec)
      assert {:error, :host_already_owned} = Lock.acquire(pool_directory)
      assert Lock.current() == placement
    after
      send(holder.pid, {:release_pool, ready})
      assert :ok = Task.await(holder, 5000)
      assert :ok = Lock.release(placement)
      File.rm_rf!(root)
    end
  end

  # @cc [owner:ghuntley,label:verification;isolation;recovery] memory-relocation-network-compatibility-tested
  # RAM continuation MUST retain its source profile/slot and complete machine
  # shape even when placement/pool change. Different slot/profile admission
  # would route a source guest address into another tenant's allocation.
  property "relocated RAM retains its original slot and shape under new host identities" do
    profile = Hegel.draw("source guest profile", member_of([:customer, :standard, :oss]))
    slot = Hegel.draw("source guest slot", integer(2..65533))
    other_slot = slot + 1
    {pool, base} = fixture("/fixture")

    source_values = %{
      id: base.id,
      image_id: base.image_id,
      pool_id: base.pool_id,
      profile: profile,
      slot: slot,
      vcpu: base.vcpu,
      memory_bytes: base.memory_bytes,
      disk_bytes: base.disk_bytes
    }

    {:ok, source} = Spec.new(source_values)
    {:ok, destination} = Spec.new(%{source_values | id: @other, pool_id: @other})
    manifest = states(pool, source, 3).ready["manifest"]
    assert Checkpoint.workload_matches?(manifest, destination)

    for {key, value} <- [
          {"slot", other_slot},
          {"profile", if(profile == :customer, do: "standard", else: "customer")},
          {"image_id", "sha256:" <> String.duplicate("b", 64)},
          {"vcpu", source.vcpu + 1},
          {"memory_bytes", source.memory_bytes + 1_048_576},
          {"disk_bytes", source.disk_bytes + 1_048_576}
        ] do
      changed = put_in(manifest, ["workload", key], value)
      changed = if(key == "memory_bytes", do: %{changed | "memory_bytes" => value}, else: changed)
      assert Checkpoint.valid_manifest?(changed)
      refute Checkpoint.workload_matches?(changed, destination)
    end

    refute Checkpoint.workload_matches?(nil, destination)
    refute Checkpoint.workload_matches?(Map.put(manifest, "extra", true), destination)
  end

  # @cc [owner:ghuntley,label:verification;recovery] interrupted-loaded-restore-journal-model
  # Reopening a consumed restore before or after PATCH Resumed MUST permit only
  # continuation of the same authority, never a second snapshot load. A process
  # that never loaded RAM MUST refuse. Native incarnation/confinement is separate
  # evidence; this property checks the real durable journal and action boundary.
  property "loaded paused restores finish across interruptions without reopening RAM authority",
    test_cases: 30 do
    generation = Hegel.draw("restore generation", integer(3..1_000_000))

    events =
      Hegel.draw(
        "interrupted reconciliation history",
        list_of(member_of([:reconcile, :restart, :interrupt_after_patch, :foreign_authority]),
          max_length: 20
        )
      )

    root = Path.join(System.tmp_dir!(), "checkpoint-live-restore-" <> Lilly.UUID.generate())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {pool, spec} = fixture(root)
      states = states(pool, spec, generation)

      for state <- [states.empty, states.capturing, states.copied, states.ready, states.restoring],
          do: assert(:ok = Journal.write(Machine, root, "checkpoint.json", state))

      authority = states.restoring["restore_authority"]
      assert {:error, _} = Checkpoint.restore_action(states.ready, authority, :paused)
      assert {:error, _} = Checkpoint.restore_action(states.restoring, authority, :unconfigured)

      state =
        Enum.reduce(events, :paused, fn event, api_state ->
          assert {:ok, reopened} = Journal.load(Machine, root, "checkpoint.json")

          case event do
            :restart ->
              assert reopened.payload["phase"] in ["restoring", "consumed"]
              api_state

            :foreign_authority ->
              foreign = Map.put(authority, "generation", generation + 1)
              assert {:error, _} = Checkpoint.restore_action(reopened.payload, foreign, api_state)
              api_state

            continuation ->
              assert {:ok, action} =
                       Checkpoint.restore_action(reopened.payload, authority, api_state)

              assert action == if(api_state == :paused, do: :resume, else: :adopt)

              if continuation == :reconcile do
                assert :ok =
                         Journal.write(Machine, root, "checkpoint.json", states.consumed)
              end

              :running
          end
        end)

      assert {:ok, reopened} = Journal.load(Machine, root, "checkpoint.json")
      assert {:ok, action} = Checkpoint.restore_action(reopened.payload, authority, state)
      assert action in [:resume, :adopt]
      assert :ok = Journal.write(Machine, root, "checkpoint.json", states.consumed)
      assert {:ok, finished} = Journal.load(Machine, root, "checkpoint.json")
      assert finished.payload["phase"] == "consumed"
      assert finished.payload["descriptor"] == states.ready["descriptor"]
      assert {:error, _} = Journal.write(Machine, root, "checkpoint.json", states.ready)
    after
      :ok = Lock.release(lock)
      File.rm_rf!(root)
    end
  end

  property "shape rebinding requires an empty journal with no retained RAM slots" do
    {pool, spec} = fixture("/fixture")
    memory = Hegel.draw("new memory MiB", integer(512..262_144)) * 1_048_576
    empty = Checkpoint.initial(pool, spec)
    changed = Checkpoint.initial(pool, %{spec | memory_bytes: memory})
    assert Machine.valid_transition?(empty, changed)
    refute Machine.valid_transition?(states(pool, spec, 3).empty, changed)
    refute Machine.valid_transition?(states(pool, spec, 3).ready, changed)

    refute Machine.valid_transition?(
             empty,
             put_in(changed, ["binding", "parent_dataset_guid"], "9")
           )

    refute Machine.valid_transition?(empty, put_in(changed, ["binding", "host_id"], @other))
  end

  property "RAM receive intent reopens before native bytes and only retires under its binding",
    test_cases: 30 do
    nonce = Hegel.draw("local receive nonce", binary(length: 16)) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "checkpoint-receive-" <> Lilly.UUID.generate())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {pool, spec} = fixture(root)
      empty = Checkpoint.initial(pool, spec)
      descriptor = states(pool, spec, 3).ready["descriptor"]
      {:ok, checkpoint} = OverallsProtocol.Checkpoint.decode(descriptor)

      transfer = %{
        relocation_id: @other,
        vm_id: @other,
        source: %{placement_id: @other, host_id: @other, pool_id: @other},
        destination: %{placement_id: spec.id, host_id: pool.host_id, pool_id: pool.id},
        source_epoch: 1,
        destination_epoch: 2,
        workload:
          Spec.encode(spec)
          |> Map.drop(~w(id pool_id))
          |> Map.put("architecture", "x86_64"),
        checkpoint: checkpoint,
        stream: %{source_dataset_guid: "10", to_guid: "11"}
      }

      # Build the public transfer through its closed wire codec, independently
      # of the private receiving journal shape.
      wire = %{
        "version" => 3,
        "relocation_id" => transfer.relocation_id,
        "vm_id" => transfer.vm_id,
        "source" => Map.new(transfer.source, fn {key, value} -> {Atom.to_string(key), value} end),
        "destination" =>
          Map.new(transfer.destination, fn {key, value} -> {Atom.to_string(key), value} end),
        "source_epoch" => transfer.source_epoch,
        "destination_epoch" => transfer.destination_epoch,
        "workload" => transfer.workload,
        "checkpoint" => descriptor,
        "stream" => %{"source_dataset_guid" => "10", "to_guid" => "11"}
      }

      assert {:ok, _} = OverallsProtocol.Relocation.descriptor(wire)

      receiving = %{
        empty
        | "phase" => "receiving",
          "slot" => "a",
          "checkpoint_id" => checkpoint.id,
          "descriptor" => descriptor,
          "relocation" => wire,
          "slots" => %{
            "a" => %{
              "state" => "creating",
              "nonce" => nonce,
              "dataset_guid" => nil,
              "snapshot_guid" => nil,
              "checkpoint_id" => checkpoint.id
            }
          }
      }

      assert :ok = Journal.write(Machine, root, "checkpoint.json", empty)
      assert :ok = Journal.write(Machine, root, "checkpoint.json", receiving)
      assert {:ok, %{payload: ^receiving}} = Journal.load(Machine, root, "checkpoint.json")

      assert {:error, _} =
               Journal.write(Machine, root, "checkpoint.json", %{
                 receiving
                 | "checkpoint_id" => @other
               })

      assert :ok =
               Journal.write(Machine, root, "checkpoint.json", %{receiving | "phase" => "retired"})

      assert :ok = Journal.write(Machine, root, "checkpoint.json", empty)
    after
      Lock.release(lock)
      File.rm_rf!(root)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery;security] checkpoint-cleanup-shape-refusals-tested
  # The same pure native observation predicate used by destructive cleanup MUST
  # accept only journal-nonce/GUID-bound exact leaves, including inert receives
  # and absent retired snapshots. These properties do not establish native ZFS.
  property "interrupted RAM cleanup refuses unknown children, GUIDs and snapshot markers" do
    {pool, spec} = fixture("/fixture")
    dataset = CheckpointStorage.name(pool, spec.id, "a")
    snapshot = dataset <> "@lilly-checkpoint"

    mounted =
      Hegel.draw("mount state", member_of([{"yes", "on"}, {"no", "noauto"}, {"no", "on"}]))

    {is_mounted, canmount} = mounted

    row = %{
      "type" => "filesystem",
      "guid" => "3",
      "mountpoint" => CheckpointStorage.path(pool, spec.id, "a"),
      "mounted" => is_mounted,
      "compression" => "lz4",
      "reservation" => 0,
      "refreservation" => 0,
      "dedup" => "off",
      "sync" => "standard",
      "origin" => "-",
      "used" => 10,
      "available" => 100,
      "logicalused" => 10,
      "quota" => OverallsProtocol.VMShape.checkpoint_bytes(spec.memory_bytes),
      "compressratio" => 1.0,
      "usedbychildren" => 0,
      "usedbydataset" => 10,
      "usedbyrefreservation" => 0,
      "usedbysnapshots" => 0,
      "refquota" => 0,
      "readonly" => "on",
      "canmount" => canmount
    }

    leaf = %{
      "state" => "creating",
      "nonce" => String.duplicate("b", 32),
      "dataset_guid" => "3",
      "snapshot_guid" => nil,
      "checkpoint_id" => @id
    }

    owner = %{
      "guid" => "3",
      "host" => pool.host_id,
      "pool" => pool.id,
      "vm" => spec.id,
      "nonce" => leaf["nonce"]
    }

    observed = %{rows: %{dataset => row}, owners: %{dataset => owner}, marker: false}
    assert CheckpointStorage.cleanup_observation?(pool, spec, "a", leaf, observed)

    refute CheckpointStorage.cleanup_observation?(
             pool,
             spec,
             "a",
             %{leaf | "dataset_guid" => "9"},
             observed
           )

    refute CheckpointStorage.cleanup_observation?(
             pool,
             spec,
             "a",
             %{leaf | "nonce" => String.duplicate("c", 32)},
             observed
           )

    with_snapshot = %{
      observed
      | rows: Map.put(observed.rows, snapshot, %{"type" => "snapshot", "guid" => "4"}),
        owners: Map.put(observed.owners, snapshot, %{owner | "guid" => "4"})
    }

    refute CheckpointStorage.cleanup_observation?(pool, spec, "a", leaf, with_snapshot)

    assert CheckpointStorage.cleanup_observation?(pool, spec, "a", leaf, %{
             with_snapshot
             | marker: true
           })

    known = %{leaf | "snapshot_guid" => "4"}
    assert CheckpointStorage.cleanup_observation?(pool, spec, "a", known, with_snapshot)

    refute CheckpointStorage.cleanup_observation?(
             pool,
             spec,
             "a",
             %{known | "snapshot_guid" => "5"},
             with_snapshot
           )

    assert CheckpointStorage.cleanup_observation?(pool, spec, "a", known, observed)

    extra = put_in(observed, [:rows, dataset <> "/unowned"], row)
    refute CheckpointStorage.cleanup_observation?(pool, spec, "a", leaf, extra)
  end

  property "only canonical checkpoint roots and fixed placement jail binds are admissible" do
    {pool, spec} = fixture("/fixture")
    slot = Hegel.draw("RAM slot", member_of(["a", "b"]))

    {file, fsroot} =
      Hegel.draw(
        "allowed jail bind",
        member_of([
          {"checkpoint-" <> slot, "/output"},
          {"restore.memory", "/output/memory"},
          {"restore.state", "/output/state"}
        ])
      )

    dataset = CheckpointStorage.name(pool, spec.id, slot)
    directory = CheckpointStorage.path(pool, spec.id, slot)
    root = %{"source" => dataset, "target" => directory, "fstype" => "zfs", "fsroot" => "/"}

    bind = %{
      "source" => dataset <> "[" <> fsroot <> "]",
      "target" => Path.join(Lilly.VM.Jail.root(pool, spec), file),
      "fstype" => "zfs",
      "fsroot" => fsroot
    }

    assert CheckpointStorage.mounts_valid?(pool, spec.id, slot, [], :unmounted, false)
    assert CheckpointStorage.mounts_valid?(pool, spec.id, slot, [root], :mounted, false)
    assert CheckpointStorage.mounts_valid?(pool, spec.id, slot, [root, bind], :mounted, true)
    refute CheckpointStorage.mounts_valid?(pool, spec.id, slot, [root, bind], :mounted, false)
    refute CheckpointStorage.mounts_valid?(pool, spec.id, slot, [bind], :unmounted, false)

    refute CheckpointStorage.mounts_valid?(
             pool,
             spec.id,
             slot,
             [root, bind, bind],
             :mounted,
             true
           )

    for alias_mount <- [
          %{root | "target" => "/unowned"},
          %{bind | "target" => "/unowned"},
          %{root | "source" => dataset <> "@lilly-checkpoint", "target" => "/unowned"}
        ] do
      refute CheckpointStorage.mounts_valid?(
               pool,
               spec.id,
               slot,
               [root, alias_mount],
               :mounted,
               true
             )
    end
  end

  test "continuation retains guest identity while current host authority advances", %{
    tmp_dir: root
  } do
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {:ok, intent} = Intent.set(root, @other, {9, 4}, :running)

      manifest = %{
        "guest_identity" => %{
          "placement_id" => @id,
          "execution_epoch" => 1,
          "boot_challenge" => String.duplicate("b", 64)
        },
        "guest_boot_id" => @id
      }

      assert {:ok, boot} = Boot.continue(root, intent, manifest, @id)
      assert boot.placement_id == @other and boot.execution_epoch == 9 and boot.generation == 4

      assert Boot.expectation(boot) == %{
               placement_id: @id,
               execution_epoch: 1,
               boot_challenge: String.duplicate("b", 64)
             }

      assert boot.guest_boot_id == @id
      assert {:ok, ^boot} = Boot.current(root, @other, {9, 4})
      assert :ok = Boot.record_boot_id(root, boot, @id)
      assert {:error, _} = Boot.record_boot_id(root, boot, @other)
      assert {:ok, _} = Intent.set(root, @other, {9, 5}, :paused)
      assert {:error, _} = Boot.current(root, @other, {9, 4})
    after
      Lock.release(lock)
    end
  end

  test "corrupt checkpoint payload is preserved and never repaired", %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    {:ok, lock} = Lock.acquire(root)

    try do
      {pool, spec} = fixture(root)
      assert :ok = Checkpoint.write(pool, spec.id, Checkpoint.initial(pool, spec))
      directory = Checkpoint.directory(pool, spec.id)
      assert :ok = PrivateFiles.write(directory, "checkpoint.json", "broken")
      assert {:error, :checkpoint_unconfirmed} = Checkpoint.read(pool, spec.id)

      assert {:error, :checkpoint_unconfirmed} =
               Checkpoint.write(pool, spec.id, Checkpoint.initial(pool, spec))

      assert File.read!(Path.join(directory, "checkpoint.json")) == "broken"
    after
      Lock.release(lock)
    end
  end

  @spec fixture(Path.t()) :: {Pool.t(), Spec.t()}
  defp fixture(root) do
    pool = %Pool{
      id: @id,
      host_id: @id,
      path: root,
      filesystem_id: "zfs:1:2",
      storage: %{backend: :zfs, dataset: "tank/lilly", zpool_guid: "1", dataset_guid: "2"}
    }

    {:ok, spec} =
      Spec.new(%{
        id: @id,
        image_id: @hash,
        pool_id: @id,
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    {pool, spec}
  end

  @spec states(Pool.t(), Spec.t(), pos_integer()) :: %{atom() => Checkpoint.journal_record()}
  defp states(pool, spec, generation) do
    leaf = %{
      "state" => "empty",
      "nonce" => String.duplicate("b", 32),
      "dataset_guid" => "3",
      "snapshot_guid" => nil,
      "checkpoint_id" => nil
    }

    empty = put_in(Checkpoint.initial(pool, spec), ["slots", "a"], leaf)
    capture_authority = %{"placement_id" => @id, "execution_epoch" => 1, "generation" => 2}

    manifest = %{
      "version" => 1,
      "id" => @id,
      "compatibility" => @hash,
      "guest_identity" => %{
        "placement_id" => @id,
        "execution_epoch" => 1,
        "boot_challenge" => String.duplicate("a", 64)
      },
      "guest_boot_id" => @id,
      "workload" => Spec.encode(spec),
      "source_authority" => capture_authority,
      "memory_bytes" => spec.memory_bytes,
      "slot" => "a"
    }

    capturing = %{
      empty
      | "phase" => "capturing",
        "slot" => "a",
        "checkpoint_id" => @id,
        "manifest" => manifest,
        "capture_authority" => capture_authority
    }

    copied = put_in(%{capturing | "phase" => "copied"}, ["slots", "a", "checkpoint_id"], @id)

    descriptor = %{
      id: @id,
      memory_bytes: spec.memory_bytes,
      state_bytes: 4096,
      compatibility: @hash,
      memory_sha256: @hash,
      state_sha256: @hash,
      manifest_sha256: @hash,
      dataset_guid: "3",
      snapshot_guid: "4"
    }

    ready = %{
      copied
      | "phase" => "ready",
        "descriptor" => OverallsProtocol.Checkpoint.encode(descriptor),
        "slots" => %{
          "a" => %{leaf | "state" => "sealed", "snapshot_guid" => "4", "checkpoint_id" => @id}
        }
    }

    restoring = %{
      ready
      | "phase" => "restoring",
        "restore_authority" => %{
          "placement_id" => @id,
          "execution_epoch" => 1,
          "generation" => generation
        }
    }

    %{
      empty: empty,
      capturing: capturing,
      copied: copied,
      ready: ready,
      restoring: restoring,
      consumed: %{restoring | "phase" => "consumed"}
    }
  end
end
