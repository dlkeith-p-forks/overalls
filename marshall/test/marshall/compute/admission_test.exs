defmodule Marshall.Compute.AdmissionTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    HostReports,
    Image,
    Images,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    ServiceLevelAttempt,
    VirtualMachine,
    WorkloadPlacement
  }

  setup do
    Map.put(host_fixture(), :user, user())
  end

  # @cc [owner:ghuntley,label:verification;security] native-admission-exact-image-oracle
  # A valid native manifest with unreviewed bytes MUST refuse admission with
  # image_requirements_not_met before creating any VM, placement, reservation,
  # address, operation, audit version or dispatch job, including source-bearing
  # requests whose unreviewed manifests declare source protocol 2.
  test "unapproved native identities refuse before address and host allocation", %{user: user} do
    reviewed = OverallsProtocol.NativeAdmission.reviewed_manifest()

    manifests = [
      native_image_manifest("freebsd", "freebsd-v1"),
      native_image_manifest("illumos", "illumos-v1"),
      put_in(reviewed, ["root", "sha256"], String.duplicate("e", 64)),
      Map.put(reviewed, "workspace_source_version", nil)
    ]

    before = admission_inventory()
    assert Enum.all?(Map.values(before), &(&1 == []))

    assert {:ok, source} =
             OverallsProtocol.WorkspaceSource.parse_url("https://github.com/overalls/demo")

    for manifest <- manifests, source <- [nil, source] do
      assert {:ok, image} = Images.register(manifest, "unreviewed native")

      params =
        Image.default_shape(image)
        |> Map.merge(%{image_id: image.id, workspace_source: source})
        |> request()

      assert {:error, %{errors: [%Compute.Error{reason: :image_requirements_not_met}]}} =
               Compute.provision(params, actor: user)

      assert admission_inventory() == before
    end
  end

  test "the exact reviewed native image admits through ordinary capacity and readiness accounting",
       c do
    assert {:ok, image} =
             Images.register(
               OverallsProtocol.NativeAdmission.reviewed_manifest(),
               "reviewed FreeBSD"
             )

    pool_bytes = 128 * 1_073_741_824
    [pool_report] = c.report.pools

    pool_report = %{
      pool_report
      | total_bytes: pool_bytes,
        free_bytes: pool_bytes,
        storage: storage_observation(c.pool, pool_bytes, pool_bytes)
    }

    report = %{
      c.report
      | sequence: 2,
        inventory: Map.put(c.report.inventory, "images", [image_id(), image.id]),
        pools: [pool_report]
    }

    assert {:ok, :ok} = HostReports.ingest(c.host.id, c.epoch, report)
    params = request(Map.put(Image.default_shape(image), :image_id, image.id))
    assert {:ok, vm} = Compute.provision(params, actor: c.user)
    assert vm.image_id == image.id
    assert vm.host_id == c.host.id
    assert [%{vm_id: vm_id}] = Ledger.read!(Reservation)
    assert vm_id == vm.id
    assert [%{vm_id: ^vm_id, id: operation_id}] = Ledger.read!(Operation)

    assert Ledger.read!(ServiceLevelAttempt, operation_id: operation_id)
           |> Enum.map(& &1.service)
           |> Enum.sort() == [:lilly_physical, :marshall_ready]
  end

  test "exactly 500 GiB is admitted when physical capacity is available", c do
    capacity = 600 * 1_073_741_824
    [pool_report] = c.report.pools

    pool_report = %{
      pool_report
      | total_bytes: capacity,
        free_bytes: capacity,
        storage: storage_observation(c.pool, capacity, capacity)
    }

    report = %{c.report | sequence: 2, pools: [pool_report]}
    assert {:ok, :ok} = Marshall.Compute.HostReports.ingest(c.host.id, c.epoch, report)
    assert {:ok, vm} = Compute.provision(request(%{disk_bytes: 536_870_912_000}), actor: c.user)
    assert vm.disk_bytes == 536_870_912_000
  end

  test "admission diagnostics follow the catalog after commit and refusal", c do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {{:ok, vm}, reserved} =
      ExUnit.CaptureLog.with_log([metadata: [:event, :vm_id, :host_id]], fn ->
        Compute.provision(request(), actor: c.user)
      end)

    assert reserved =~ "VM capacity reserved"
    assert reserved =~ "event=vm.capacity_reserved"
    assert reserved =~ "vm_id=" <> vm.id
    assert reserved =~ "host_id=" <> vm.host_id

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        Ledger.update!(c.host, :report, %{capacity: capacity(0, 0)})

        assert {:error, _} =
                 Compute.provision(request(%{idempotency_key: Ash.UUID.generate()}),
                   actor: c.user
                 )
      end)

    assert refused =~ "VM admission refused"
    assert refused =~ "event=vm.admission_refused"
    assert refused =~ "reason=insufficient_capacity"
  end

  test "oversized disks reject before allocation", %{user: user} do
    for disk <- [536_870_916_096, 501 * 1_073_741_824] do
      assert {:error, _} = Compute.provision(request(%{disk_bytes: disk}), actor: user)
    end

    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(Operation) == []
  end

  test "fresh inventory without executable readiness cannot admit work", %{
    host: host,
    user: user,
    report: report
  } do
    for ready <- [false, nil, "true"] do
      Ledger.update!(host, :report, %{
        inventory: Map.put(report.inventory, "execution_ready", ready)
      })

      assert {:error, _} = Compute.provision(request(), actor: user)
    end

    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(Operation) == []
  end

  test "acceptance commits one VM, reservation, operation, audit version and AshOban job", %{
    user: user
  } do
    assert {:ok, vm} = Compute.provision(request(), actor: user)
    assert [%{vm_id: vm_id, memory_bytes: reserved_memory}] = Ledger.read!(Reservation)
    assert vm_id == vm.id
    assert reserved_memory == vm.memory_bytes + 67_108_864
    assert [%{vm_id: ^vm_id, id: operation_id}] = Ledger.read!(Operation)
    assert [%{version_source_id: ^vm_id, changes: changes}] = Ledger.read!(VirtualMachine.Version)
    assert changes["owner_id"] == user.id

    assert [%{args: %{"primary_key" => %{"id" => ^operation_id}}}] =
             Oban.Testing.all_enqueued(
               repo: Marshall.Repo,
               worker: Marshall.Compute.Workers.Dispatch
             )
  end

  test "same request key returns the original VM; a changed payload is rejected", %{user: user} do
    params = request()
    assert {:ok, vm} = Compute.provision(params, actor: user)
    assert {:ok, %{id: id}} = Compute.provision(params, actor: user)
    assert id == vm.id
    assert {:error, error} = Compute.provision(%{params | vcpu: 1}, actor: user)
    assert Exception.message(error) =~ "idempotency_conflict"
    assert length(Ledger.read!(Reservation)) == 1
    assert length(Ledger.read!(Operation)) == 1
  end

  # @cc [owner:ghuntley,label:verification;recovery] archived-admission-replay-inventory
  # Every same-key replay after VM archival MUST return the original ID without
  # creating another allocation record or dispatch job; changed shape MUST
  # refuse with the same complete inventory.
  property "archived admission replays retain the complete allocation inventory",
    test_cases: 100 do
    repeats = draw("repeats", integer(1..4))

    changed =
      draw(
        "changed",
        member_of([%{vcpu: 1}, %{memory_bytes: 1_073_741_824}, %{disk_bytes: 4_294_967_296}])
      )

    _fixture = host_fixture()
    actor = user()
    params = request()
    assert {:ok, vm} = Compute.provision(params, actor: actor)
    assert :ok = Ledger.archive!(vm, :archive)
    before = admission_inventory()

    for _ <- 1..repeats do
      assert {:ok, %{id: id}} = Compute.provision(params, actor: actor)
      assert id == vm.id
      assert admission_inventory() == before
    end

    assert {:error, error} = Compute.provision(Map.merge(params, changed), actor: actor)
    assert Exception.message(error) =~ "idempotency_conflict"
    assert admission_inventory() == before
  end

  @typep admission_inventory :: %{
           vms: [Ecto.UUID.t()],
           versions: [Ecto.UUID.t()],
           placements: [Ecto.UUID.t()],
           reservations: [Ecto.UUID.t()],
           addresses: [Ecto.UUID.t()],
           operations: [Ecto.UUID.t()],
           jobs: [pos_integer()]
         }
  @spec admission_inventory() :: admission_inventory()
  defp admission_inventory do
    %{
      vms: Ledger.history!(VirtualMachine, []) |> Enum.map(& &1.id) |> Enum.sort(),
      versions: Ledger.read!(VirtualMachine.Version) |> Enum.map(& &1.id) |> Enum.sort(),
      placements: Ledger.read!(WorkloadPlacement) |> Enum.map(& &1.id) |> Enum.sort(),
      reservations: Ledger.read!(Reservation) |> Enum.map(& &1.id) |> Enum.sort(),
      addresses: Ledger.read!(NetworkAddress) |> Enum.map(& &1.id) |> Enum.sort(),
      operations: Ledger.read!(Operation) |> Enum.map(& &1.id) |> Enum.sort(),
      jobs:
        Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Marshall.Compute.Workers.Dispatch)
        |> Enum.map(& &1.id)
        |> Enum.sort()
    }
  end

  test "duplicate AshOban delivery preserves the pending operation for reconciliation", %{
    user: user
  } do
    {:ok, vm} = Compute.provision(request(), actor: user)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    watch_hints()

    for _ <- 1..2 do
      assert {:ok, %{status: :pending}} =
               Oban.Testing.perform_job(
                 Marshall.Compute.Workers.Dispatch,
                 %{"primary_key" => %{"id" => operation.id}},
                 repo: Marshall.Repo
               )

      host = vm.host_id
      assert_receive {:hint, :host_commands, ^host}
    end

    assert [%{id: id, status: :pending}] = Ledger.read!(Operation, vm_id: vm.id)
    assert id == operation.id
    assert length(Ledger.read!(Reservation, vm_id: vm.id)) == 1
  end

  test "RAM and disk can each reject admission while CPU is available", %{
    host: host,
    user: user,
    pool: pool
  } do
    Ledger.update!(host, :report, %{capacity: capacity(5, 1_073_741_824 + 536_870_912)})

    assert {:error, _} =
             Compute.provision(request(%{vcpu: 1, memory_bytes: 1_073_741_824}), actor: user)

    Ledger.update!(host, :report, %{capacity: capacity(5, 4_294_967_296)})
    Ledger.update!(pool, :report, %{free_bytes: 1_073_741_824})
    assert {:error, _} = Compute.provision(request(%{vcpu: 1}), actor: user)
    assert [] == Ledger.read!(Reservation)
  end

  test "requests below the initial guest image limits are rejected", %{user: user} do
    assert {:error, _} = Compute.provision(request(%{memory_bytes: 134_217_728}), actor: user)
    assert {:error, _} = Compute.provision(request(%{disk_bytes: 1_073_741_824}), actor: user)
    assert [] == Ledger.read!(Reservation)
  end

  test "VMM overhead and exact size alignment are admission requirements", %{
    host: host,
    user: user
  } do
    Ledger.update!(host, :report, %{
      capacity: capacity(5, host.overhead_memory_bytes + 536_870_912)
    })

    assert {:error, error} = Compute.provision(request(%{vcpu: 1}), actor: user)
    assert Exception.message(error) =~ "insufficient_capacity"

    Ledger.update!(host, :report, %{
      capacity: capacity(5, host.overhead_memory_bytes + 536_870_912 + 67_108_864)
    })

    assert {:ok, _} = Compute.provision(request(%{vcpu: 1}), actor: user)

    for changes <- [%{memory_bytes: 536_870_913}, %{disk_bytes: 2_147_483_649}] do
      assert {:error, error} = Compute.provision(request(changes), actor: user)
      assert Exception.message(error) =~ "invalid_vm_size"
    end
  end

  test "exhaustion rejects immediately without partial records", %{user: user} do
    assert {:ok, _} = Compute.provision(request(), actor: user)
    assert {:ok, _} = Compute.provision(request(), actor: user)
    assert {:error, error} = Compute.provision(request(), actor: user)
    assert Exception.message(error) =~ "insufficient_capacity"
    assert length(Ledger.read!(Reservation)) == 2
    assert length(Ledger.read!(VirtualMachine)) == 2
  end

  test "stale, disabled and architecture-incompatible hosts cannot admit", %{
    host: host,
    user: user
  } do
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -10, :second)})
    assert {:error, error} = Compute.provision(request(), actor: user)
    assert Exception.message(error) =~ "insufficient_capacity"
    Ledger.update!(host, :configure, %{enabled: false})
    assert {:error, _} = Compute.provision(request(), actor: user)
    assert {:error, _} = Compute.provision(request(%{architecture: :aarch64}), actor: user)
    assert [] == Ledger.read!(Reservation)
  end

  test "Ash denies anonymous provision and direct user access to internal resources", %{
    user: user
  } do
    assert {:error, _} = Compute.provision(request())
    assert {:error, _} = Ash.read(Host, actor: user)
    assert {:error, _} = Ash.read(VirtualMachine, actor: user)
    assert {:error, _} = Ash.read(VirtualMachine.Version, actor: user)
    assert [] == Ledger.read!(Reservation)
  end

  @spec watch_hints() :: :ok
  defp watch_hints do
    parent = self()
    handler = "hints-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _event, _measurements, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end
end
