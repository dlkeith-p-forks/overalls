defmodule Lilly.VM.ProvisioningTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.{Config, Provisioning, Spec}
  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    host = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Config.new(host, "eth0", [], "/tmp/fastpath-network")

    config = %Config{
      state_dir: root,
      network: network,
      firecracker: "/fixture/firecracker",
      jailer: "/fixture/jailer",
      unshare: "/fixture/unshare",
      launch_guard: "/fixture/guard",
      boot_log_writer: "/fixture/writer"
    }

    {:ok, spec} =
      Spec.new(%{
        id: Lilly.UUID.generate(),
        pool_id: Lilly.UUID.generate(),
        image_id: "sha256:" <> String.duplicate("a", 64),
        profile: :oss,
        slot: 101,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 4_294_967_296
      })

    boot = %{
      placement_id: spec.id,
      execution_epoch: 1,
      generation: 1,
      boot_challenge: String.duplicate("b", 64)
    }

    %{config: config, spec: spec, boot: boot, directory: Path.join(root, spec.id)}
  end

  test "recovery reuses the original deadline and exact-boot receipt without audit churn", c do
    {:ok, lock} = Lock.acquire(c.directory)

    try do
      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})
      assert :ok = Provisioning.launching(c.config, c.spec, c.boot)
      assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot)

      assert {:ok, before} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})
      assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot)

      assert {:ok, ^before} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert :ok = Provisioning.awaiting_ssh(c.config, c.spec, c.boot)
      boot_id = Lilly.UUID.generate()
      assert :ok = Provisioning.ready(c.config, c.spec, c.boot, boot_id)
      assert {:ready, ^boot_id} = Provisioning.status(c.config, c.spec, c.boot)

      assert {:error, :provisioning_unconfirmed} =
               Provisioning.status(c.config, c.spec, %{
                 c.boot
                 | boot_challenge: String.duplicate("c", 64)
               })

      assert {:error, :provisioning_unconfirmed} =
               Provisioning.status(c.config, c.spec, %{c.boot | generation: 2})

      assert {:ok, ready} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert ready.payload["deadline"] == before.payload["deadline"]
      assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot)
      assert :ok = Provisioning.awaiting_ssh(c.config, c.spec, c.boot)

      assert {:ok, ^ready} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")
    after
      Lock.release(lock)
    end
  end

  test "a concurrent metadata writer holding its lock causes a retry without starting or failing progress",
       c do
    {:ok, lock} = Lock.acquire(c.directory)
    parent = self()

    holder =
      Task.async(fn ->
        {:ok, audit} = Lock.acquire(Path.join(c.directory, "audit-lock"))
        send(parent, :audit_locked)

        receive do
          :release -> Lock.release(audit)
        end
      end)

    try do
      # Acquisition spawns the native lock helper; this waits for an event and
      # asserts no deadline, so allow for a loaded host.
      assert_receive :audit_locked, 5000
      assert {:error, :provisioning_busy} = Provisioning.prepare(c.config, c.spec, {1, 1})

      assert {:ok, nil} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      send(holder.pid, :release)
      assert :ok = Task.await(holder)
      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})
    after
      send(holder.pid, :release)
      Lock.release(lock)
    end
  end

  @tag :hegel
  test "foreign journals and stale cancellation cannot alter durable progress", c do
    Hegel.check(
      fn ->
        epoch = draw("epoch", integer(1..100))
        generation = draw("generation", integer(2..100))
        spec = %{c.spec | id: Lilly.UUID.generate()}
        directory = Path.join(c.config.state_dir, spec.id)
        {:ok, lock} = Lock.acquire(directory)

        try do
          assert :ok = Provisioning.prepare(c.config, spec, {epoch, generation})

          assert {:ok, before} =
                   Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

          assert before.payload["launched_at"] == nil
          assert before.payload["deadline"] == nil
          foreign = %{c.config | network: %{c.config.network | host_id: Lilly.UUID.generate()}}

          assert {:error, :provisioning_unconfirmed} =
                   Provisioning.cancel(foreign, spec, {epoch, generation})

          assert {:error, :provisioning_unconfirmed} =
                   Provisioning.fail(foreign, spec, {epoch, generation})

          assert {:error, :provisioning_unconfirmed} =
                   Provisioning.cancel(c.config, spec, {epoch, generation - 1})

          assert {:ok, ^before} =
                   Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

          assert :ok = Provisioning.cancel(c.config, spec, {epoch, generation})

          assert {:ok, after_record} =
                   Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

          assert after_record.state == :superseded
          assert :ok = Provisioning.cancel(c.config, spec, {epoch, generation})

          assert {:ok, ^after_record} =
                   Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")
        after
          Lock.release(lock)
        end
      end,
      test_cases: 100
    )
  end

  test "launching records the caller's readiness budget once and keeps it on relaunch", c do
    {:ok, lock} = Lock.acquire(c.directory)

    try do
      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})
      windows = OverallsProtocol.GuestAgents.readiness_budget_ms(:windows_v1, :customer)
      assert windows == 600_000
      assert :ok = Provisioning.launching(c.config, c.spec, c.boot, windows)

      assert {:ok, %{state: :launching, payload: payload}} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert payload["deadline"] == payload["launched_at"] + windows

      # A relaunch of the same boot never extends the deadline, whatever budget
      # the caller passes; a kernel guest without a budget gets the Linux one.
      assert :ok = Provisioning.launching(c.config, c.spec, c.boot, 1)

      assert {:ok, %{payload: ^payload}} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert OverallsProtocol.GuestAgents.readiness_budget_ms(:linux, c.spec.network.profile) ==
               120_000
    after
      Lock.release(lock)
    end
  end

  test "awaiting trust preserves a native agent-set budget when first launch has no deadline",
       c do
    {:ok, lock} = Lock.acquire(c.directory)

    try do
      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})

      for agents <- [:freebsd_v1, :illumos_v1] do
        budget = OverallsProtocol.GuestAgents.readiness_budget_ms(agents, :customer)
        assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot, budget)

        assert {:ok, %{state: :awaiting_trust, payload: payload}} =
                 Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

        assert payload["deadline"] == payload["launched_at"] + budget

        # The second native row must not reset a durable deadline once the
        # same boot has entered the trust phase.
        assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot, budget + 1)

        assert {:ok, %{payload: ^payload}} =
                 Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")
      end
    after
      Lock.release(lock)
    end
  end

  test "unattested commits once after awaiting_trust and refuses a later ready receipt", c do
    {:ok, lock} = Lock.acquire(c.directory)

    try do
      assert :ok = Provisioning.prepare(c.config, c.spec, {1, 1})
      assert :ok = Provisioning.launching(c.config, c.spec, c.boot)
      assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot)
      assert :ok = Provisioning.unattested(c.config, c.spec, c.boot)

      assert {:ok, %{state: :unattested, revision: revision} = record} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert is_nil(record.payload["boot_id"])
      assert record.payload["boot_challenge"] == c.boot.boot_challenge
      assert :unattested = Provisioning.status(c.config, c.spec, c.boot)

      # Idempotent: the same commit neither appends audit history nor changes state,
      # and the trust step that precedes it on restart or adoption stays a no-op.
      assert :ok = Provisioning.awaiting_trust(c.config, c.spec, c.boot)
      assert :ok = Provisioning.unattested(c.config, c.spec, c.boot)

      assert {:ok, %{state: :unattested, revision: ^revision}} =
               Journal.load(Lilly.Lifecycle.Provisioning, c.directory, "provisioning.json")

      assert {:error, :provisioning_unconfirmed} =
               Provisioning.ready(c.config, c.spec, c.boot, Lilly.UUID.generate())

      assert {:error, :provisioning_unconfirmed} =
               Provisioning.awaiting_ssh(c.config, c.spec, c.boot)

      assert :unattested = Provisioning.status(c.config, c.spec, c.boot)
    after
      Lock.release(lock)
    end
  end
end
