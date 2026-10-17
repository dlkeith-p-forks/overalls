defmodule Marshall.Compute.WorkspaceSourceAdmissionTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias OverallsProtocol.{Execution, WorkspaceSource}
  alias Marshall.Compute

  alias Marshall.Compute.{
    CommandSnapshot,
    Image,
    Images,
    Ledger,
    Operation,
    Reservation,
    VirtualMachine
  }

  alias Marshall.Compute.WorkspaceSource, as: StoredSource

  @moduletag :capture_log

  @sources [
    "https://github.com/tastejs/todomvc",
    "https://github.com/elixir-lang/elixir/tree/main",
    "https://github.com/phoenixframework/phoenix/commit/0123456789abcdef0123456789abcdef01234567",
    "https://github.com/ash-project/ash/pull/42",
    "https://gitlab.com/groups/team/project/-/tree/main",
    "https://codeberg.org/forgejo/forgejo/src/branch/main",
    "https://bitbucket.org/team/project/src/main"
  ]

  @big 1_099_511_627_776

  setup do
    fixture = host_fixture()
    fixture |> Map.put(:user, user()) |> Map.put(:sequence, 1) |> refresh()
  end

  # @cc [owner:ghuntley,label:verification;security] workspace-source-admission-oracle
  # Generated admissions MUST return the original VM for the same key and source,
  # conflict for the same key with any other source (including none), and refuse
  # a source on a profile without egress without creating any allocation.
  property "the workspace source joins idempotent admission identity", c do
    check all(
            first <- member_of([nil | @sources]),
            second <- member_of([nil | @sources]),
            profile <- member_of([:standard, :oss]),
            max_runs: 12
          ) do
      refresh(Map.put(c, :sequence, System.unique_integer([:positive, :monotonic]) + 1))
      key = Ash.UUID.generate()
      first_source = source(first)
      second_source = source(second)

      assert {:ok, vm} =
               Compute.provision(request(key, profile, first_source), actor: c.user)

      before = counts()

      if first_source == second_source do
        assert {:ok, %{id: id}} =
                 Compute.provision(request(key, profile, second_source), actor: c.user)

        assert id == vm.id
      else
        assert {:error, %{errors: [%Compute.Error{reason: :idempotency_conflict}]}} =
                 Compute.provision(request(key, profile, second_source), actor: c.user)
      end

      assert counts() == before
      stored = Ledger.read!(StoredSource, vm_id: vm.id)
      assert Enum.map(stored, &StoredSource.protocol/1) == List.wrap(first_source)
    end
  end

  property "a source on a profile without egress is refused before allocation", c do
    check all(url <- member_of(@sources), max_runs: 4) do
      before = counts()

      assert {:error, %{errors: [%Compute.Error{reason: :workspace_source_not_allowed}]}} =
               Compute.provision(request(Ash.UUID.generate(), :customer, source(url)),
                 actor: c.user
               )

      assert counts() == before
    end
  end

  test "a malformed source map is refused before allocation", c do
    before = counts()
    bad = %{provider: :github, namespace: ["-x"], repository: "r", revision: %{kind: :default}}

    assert {:error, %{errors: [%Compute.Error{reason: :invalid_workspace_source}]}} =
             Compute.provision(request(Ash.UUID.generate(), :oss, bad), actor: c.user)

    assert counts() == before
  end

  # @cc [owner:ghuntley,label:verification;security] workspace-image-capability-admission-oracle
  # Source requests MUST refuse absent or stale capabilities for every provider
  # without changing allocation inventory. A matching explicit v4 capability
  # MUST allow the normal transaction; package/name hints never grant it.
  property "every provider requires an explicit source-capable image before allocation", c do
    check all(url <- member_of(@sources), max_runs: 7) do
      manifest = Map.put(image_manifest(), "workspace_source_version", nil)
      {:ok, image} = Images.register(manifest, "receiver-installed-hint")
      before = counts()

      params =
        request(Ash.UUID.generate(), :oss, source(url))
        |> Map.put(:image_id, image.id)

      assert {:error, %{errors: [%Compute.Error{reason: :workspace_source_unavailable}]}} =
               Compute.provision(params, actor: c.user)

      assert counts() == before
    end
  end

  test "stale, malformed and mismatched persisted manifests refuse before allocation", c do
    [image] = Ledger.read!(Image, id: image_id())

    for manifest <- [
          image.manifest |> Map.delete("workspace_source_version") |> Map.put("version", 2),
          image.manifest |> Map.put("version", 3),
          image.manifest |> Map.put("workspace_source_version", 1),
          image.manifest |> Map.put("boot_args", "console=ttyS0 changed")
        ] do
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE compute_images SET manifest = $1 WHERE id = $2",
        [manifest, image.id]
      )

      before = counts()

      assert {:error, %{errors: [%Compute.Error{reason: :workspace_source_unavailable}]}} =
               Compute.provision(request(Ash.UUID.generate(), :oss, source(hd(@sources))),
                 actor: c.user
               )

      assert {:error, %{errors: [%Compute.Error{reason: :image_unavailable}]}} =
               Compute.provision(request(Ash.UUID.generate(), :oss, nil), actor: c.user)

      assert counts() == before
    end
  end

  test "the provision snapshot carries the source only for sourced VMs", c do
    source = source(hd(@sources))

    assert {:ok, sourced} =
             Compute.provision(request(Ash.UUID.generate(), :oss, source), actor: c.user)

    assert {:ok, plain} =
             Compute.provision(request(Ash.UUID.generate(), :oss, nil), actor: c.user)

    [sourced_op] = Ledger.read!(Operation, vm_id: sourced.id)
    [plain_op] = Ledger.read!(Operation, vm_id: plain.id)

    assert {:ok, %{workspace_source: ^source, kind: :provision}} =
             Execution.command(sourced_op.command_snapshot)

    refute Map.has_key?(plain_op.command_snapshot, "workspace_source")
    assert {:ok, command} = Execution.command(plain_op.command_snapshot)
    refute Map.has_key?(command, :workspace_source)

    # Start commands carry the source; stop and delete commands never do.
    for {kind, expected} <- [start: source, stop: nil, delete: nil] do
      {:ok, pinned} = Execution.command(sourced_op.command_snapshot)

      fields =
        pinned
        |> Map.take([:id, :vm_id, :placement_id, :execution_epoch, :generation, :host_id])
        |> Map.merge(%{kind: kind, pool_id: pinned.pool_id, owner_id: pinned.owner_id})

      snapshot = CommandSnapshot.build(fields)
      assert {:ok, command} = Execution.command(snapshot)
      assert Map.get(command, :workspace_source) == expected
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] workspace-source-retained-start-cutover
  # A fresh sourced start MUST roll back unchanged allocations and existing
  # snapshots when its durable image lacks current source capability. An
  # unsourced retained start MUST remain independent of obsolete image staging.
  test "obsolete sourced starts refuse without changing retained state or snapshots", c do
    assert {:ok, sourced} =
             Compute.provision(request(Ash.UUID.generate(), :oss, source(hd(@sources))),
               actor: c.user
             )

    assert {:ok, plain} =
             Compute.provision(request(Ash.UUID.generate(), :oss, nil), actor: c.user)

    [image] = Ledger.read!(Image, id: image_id())
    before_operations = Ledger.read!(Operation)
    before_reservations = Ledger.read!(Reservation)
    before_vms = Ledger.history!(VirtualMachine, [])

    for manifest <- [
          image.manifest |> Map.put("version", 3),
          image.manifest |> Map.put("workspace_source_version", nil),
          image.manifest |> Map.put("boot_args", "console=ttyS0 changed")
        ] do
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE compute_images SET manifest = $1, enabled = false WHERE id = $2",
        [manifest, image.id]
      )

      assert {:error, %{errors: [%Compute.Error{reason: :workspace_source_unavailable}]}} =
               Compute.lifecycle(
                 %{vm_id: sourced.id, kind: :start, idempotency_key: Ash.UUID.generate()},
                 actor: c.user
               )

      assert Ledger.read!(Operation) == before_operations
      assert Ledger.read!(Reservation) == before_reservations
      assert Ledger.history!(VirtualMachine, []) == before_vms
    end

    assert {:ok, unsourced_start} =
             Compute.lifecycle(
               %{vm_id: plain.id, kind: :start, idempotency_key: Ash.UUID.generate()},
               actor: c.user
             )

    refute Map.has_key?(unsourced_start.command_snapshot, "workspace_source")

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_images SET manifest = $1 WHERE id = $2",
      [image.manifest, image.id]
    )

    assert {:ok, sourced_start} =
             Compute.lifecycle(
               %{vm_id: sourced.id, kind: :start, idempotency_key: Ash.UUID.generate()},
               actor: c.user
             )

    assert {:ok, command} = Execution.command(sourced_start.command_snapshot)
    assert command.workspace_source == source(hd(@sources))
  end

  # Re-reports generous capacity with a fresh sample so generated admissions fit.
  @spec refresh(map()) :: map()
  defp refresh(fixture) do
    [pool] = fixture.report.pools

    report = %{
      fixture.report
      | sequence: fixture.sequence + 1,
        sampled_at: Ledger.now(),
        effective_cores: 64,
        effective_memory_bytes: 274_877_906_944,
        capacity: capacity(64, 274_877_906_944),
        pools: [
          %{
            pool
            | total_bytes: @big,
              free_bytes: @big,
              storage: storage_observation(fixture.pool, @big, @big)
          }
        ]
    }

    {:ok, :ok} = Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)
    Map.put(fixture, :sequence, fixture.sequence + 1)
  end

  @spec source(String.t() | nil) :: WorkspaceSource.t() | nil
  defp source(nil), do: nil

  defp source(url) do
    {:ok, source} = WorkspaceSource.parse_url(url)
    source
  end

  @spec request(String.t(), atom(), WorkspaceSource.t() | nil) :: map()
  defp request(key, profile, source) do
    base = request(%{idempotency_key: key, profile: profile, vcpu: 1})
    if source, do: Map.put(base, :workspace_source, source), else: base
  end

  @spec counts() :: map()
  defp counts,
    do: %{
      vms: length(Ledger.history!(VirtualMachine, [])),
      operations: length(Ledger.read!(Operation)),
      reservations: length(Ledger.read!(Reservation)),
      sources: length(Ledger.read!(StoredSource))
    }
end
