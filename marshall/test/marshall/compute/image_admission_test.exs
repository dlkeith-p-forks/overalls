defmodule Marshall.Compute.ImageAdmissionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{
    AddressAllocation,
    Host,
    HostReports,
    Image,
    Images,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    ServiceLevelAttempt,
    StoragePool,
    VirtualMachine,
    WorkloadPlacement
  }

  alias Marshall.Compute

  @typep firmware_request :: %{
           idempotency_key: String.t(),
           architecture: :x86_64,
           image_id: String.t(),
           profile: OverallsProtocol.AddressPool.profile(),
           vcpu: pos_integer(),
           memory_bytes: pos_integer(),
           disk_bytes: pos_integer()
         }

  setup do
    Map.put(host_fixture(), :user, user())
  end

  test "catalog identity is immutable, registration idempotent and user writes forbidden", %{
    user: user
  } do
    image = image_fixture()
    assert {:ok, same} = Images.register(image.manifest, "a second display name")
    assert same.id == image.id and same.name == image.name
    assert length(Ledger.read!(Image.Version, version_source_id: image.id)) == 1

    assert {:error, _} =
             Image
             |> Ash.Changeset.for_create(
               :register,
               %{name: "user image", manifest: image.manifest},
               actor: user
             )
             |> Ash.create()

    assert {:error, _} = Ash.read(NetworkAddress, actor: user)
    assert {:error, :invalid_image_manifest} = Images.register(%{}, "bad")
  end

  test "unknown, disabled or locally unavailable images cannot reserve anything", %{
    host: host,
    user: user
  } do
    assert {:error, error} =
             Compute.provision(request(%{image_id: "sha256:" <> String.duplicate("0", 64)}),
               actor: user
             )

    assert Exception.message(error) =~ "image_unavailable"
    image = image_fixture()
    Ledger.update!(image, :configure, %{enabled: false})
    assert {:error, error} = Compute.provision(request(), actor: user)
    assert Exception.message(error) =~ "image_unavailable"
    Ledger.update!(image, :configure, %{enabled: true})
    Ledger.update!(host, :report, %{inventory: %{"architecture" => "x86_64", "images" => []}})
    assert {:error, error} = Compute.provision(request(), actor: user)
    assert Exception.message(error) =~ "insufficient_capacity"
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(NetworkAddress) == []
  end

  test "manifest-specific minima and image changes are part of the idempotent request", %{
    host: host,
    user: user
  } do
    {:ok, larger} =
      Images.register(Map.put(image_manifest(), "minimum_disk_bytes", 4_294_967_296), "larger")

    Ledger.update!(host, :report, %{
      inventory: %{
        "architecture" => "x86_64",
        "images" => [image_id(), larger.id],
        "execution_ready" => true
      }
    })

    params = request(%{image_id: larger.id})
    assert {:error, error} = Compute.provision(params, actor: user)
    assert Exception.message(error) =~ "image_requirements_not_met"
    params = %{params | disk_bytes: 4_294_967_296}
    assert {:ok, vm} = Compute.provision(params, actor: user)
    assert vm.image_id == larger.id
    assert {:error, error} = Compute.provision(%{params | image_id: image_id()}, actor: user)
    assert Exception.message(error) =~ "idempotency_conflict"
    Ledger.update!(larger, :configure, %{enabled: false})
    assert {:ok, %{id: id}} = Compute.provision(params, actor: user)
    assert id == vm.id
    assert [%{vm_id: ^id, profile: :standard, slot: 2}] = Ledger.read!(NetworkAddress)
  end

  test "lost image availability rejects new intent and retains previous address and capacity", %{
    host: host,
    report: report,
    epoch: epoch,
    user: user
  } do
    assert {:ok, vm} = Compute.provision(request(), actor: user)
    report = %{report | sequence: 2, inventory: Map.put(report.inventory, "images", [])}
    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, report)
    assert {:error, _} = Compute.provision(request(), actor: user)
    assert [%{vm_id: id}] = Ledger.read!(NetworkAddress)
    assert id == vm.id
    assert [%{compute_held: true, disk_held: true}] = Ledger.read!(Reservation, vm_id: id)
    malformed = %{report | sequence: 3, inventory: Map.put(report.inventory, "images", ["bad"])}
    assert {:error, :invalid_report} = HostReports.ingest(host.id, epoch, malformed)
    assert [%{report_sequence: 2}] = Ledger.read!(Host, id: host.id)

    # Inventory is string-keyed wire data; another key spelling is refused so
    # duplicate spellings cannot bypass validation on the JSON round trip.
    malformed = %{report | sequence: 3, inventory: %{architecture: "x86_64", images: "bad"}}
    assert {:error, :invalid_report} = HostReports.ingest(host.id, epoch, malformed)
    mixed = Map.put(report.inventory, :images, "duplicate spelling")

    assert {:error, :invalid_report} =
             HostReports.ingest(host.id, epoch, %{report | sequence: 3, inventory: mixed})

    assert [%{report_sequence: 2, inventory: %{"images" => []}}] =
             Ledger.read!(Host, id: host.id)
  end

  # @cc [owner:ghuntley,label:verification;security] firmware-image-admission
  # A version-5 firmware image MUST register through the shared validator and
  # refuse Inception before allocation. ADR-0204 new admissions without Git
  # identity support MUST refuse without effects. A retained pre-identity VM
  # without guest agents MUST keep physical-only measurement; an identity-capable
  # windows-v1 admission MUST additionally measure creation-to-ready.
  test "firmware admissions require Git identity support while retained agentless VMs keep physical-only measurement",
       %{host: host, pool: pool, user: user} do
    manifest =
      windows_image_manifest()
      |> put_in(["root", "bytes"], 4_294_967_296)
      |> Map.put("minimum_disk_bytes", 4_294_967_296)
      |> Map.put("minimum_memory_bytes", 1_073_741_824)

    {:ok, windows} = Images.register(manifest, "Windows Server 2025")

    assert Image.guest_capabilities(windows) == %{
             available: true,
             adb: false,
             android_display: false,
             android_emulator: false,
             android_sdk: false,
             readiness: false,
             trust: false,
             ssh: false,
             terminal: false,
             workspace: false,
             flush: false,
             agents: false,
             editor: false,
             inception: false
           }

    Ledger.update!(host, :report, %{
      inventory: %{
        "architecture" => "x86_64",
        "images" => [image_id(), windows.id],
        "execution_ready" => true
      }
    })

    params =
      request(%{
        image_id: windows.id,
        memory_bytes: 1_073_741_824,
        disk_bytes: 4_294_967_296
      })

    # Inception is bound to the explicitly configured Inception image before the
    # guest-agents gate runs; both refusals are closed reasons and neither
    # allocates anything.
    assert {:error, error} = Compute.provision(%{params | profile: :inception}, actor: user)

    assert Exception.message(error) =~
             ~r/inception_unavailable|profile_image_mismatch|image_requirements_not_met/

    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(NetworkAddress) == []

    jobs_before = Marshall.Repo.aggregate(Oban.Job, :count)
    assert {:error, error} = Compute.provision(params, actor: user)
    assert Exception.message(error) =~ "git_identity_unavailable"
    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(WorkloadPlacement) == []
    assert Ledger.read!(Reservation) == []
    assert Ledger.read!(NetworkAddress) == []
    assert Ledger.read!(Operation) == []
    assert Ledger.read!(ServiceLevelAttempt) == []
    assert Marshall.Repo.aggregate(Oban.Job, :count) == jobs_before

    vm = retained_firmware_fixture(host, pool, user, params)
    assert vm.image_id == windows.id
    assert vm.git_identity == nil
    [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)
    refute Map.has_key?(operation.command_snapshot, "git_identity")
    attempts = Ledger.read!(ServiceLevelAttempt, operation_id: operation.id)
    assert Enum.map(attempts, & &1.service) == [:lilly_physical]

    assert {:ok, view} = Compute.get_vm(%{vm_id: vm.id}, actor: user)
    refute view.guest_capabilities.ssh
    assert view.guest_capabilities.available
    # Whatever editor release is configured, a firmware image never offers it.
    assert view.editor_image_status in [:unsupported_image, :unavailable]

    agents =
      Images.register(
        manifest
        |> Map.put("guest_agents", "windows-v1")
        |> Map.put("workspace_source_version", 2)
        |> Map.put("git_identity_version", 1),
        "Windows Server 2025 (agents)"
      )
      |> then(fn {:ok, image} -> image end)

    # A second host carries the Git identity-capable agent image.
    %{host: second} = host_fixture()

    Ledger.update!(second, :report, %{
      inventory: %{
        "architecture" => "x86_64",
        "images" => [image_id(), agents.id],
        "execution_ready" => true
      }
    })

    assert {:error, error} =
             Compute.provision(
               %{
                 params
                 | image_id: agents.id,
                   profile: :inception,
                   idempotency_key: Ash.UUID.generate()
               },
               actor: user
             )

    assert Exception.message(error) =~
             ~r/inception_unavailable|profile_image_mismatch|image_requirements_not_met/

    assert {:ok, with_agents} =
             Compute.provision(
               %{params | image_id: agents.id, idempotency_key: Ash.UUID.generate()},
               actor: user
             )

    assert with_agents.image_id == agents.id

    [operation] =
      Ledger.read!(Marshall.Compute.Operation, vm_id: with_agents.id, kind: :provision)

    attempts = Ledger.read!(Marshall.Compute.ServiceLevelAttempt, operation_id: operation.id)
    assert Enum.sort(Enum.map(attempts, & &1.service)) == [:lilly_physical, :marshall_ready]
    [ready] = Enum.filter(attempts, &(&1.service == :marshall_ready))
    assert DateTime.diff(ready.deadline, ready.admitted_at) == 600
    assert {:ok, projected} = Compute.get_vm(%{vm_id: with_agents.id}, actor: user)
    assert projected.guest_capabilities.ssh and projected.guest_capabilities.terminal
    assert projected.guest_capabilities.available
    refute projected.guest_capabilities.editor
    assert projected.editor_image_status in [:unsupported_image, :unavailable]
  end

  # @cc [owner:ghuntley,label:verification;security] retained-firmware-fixture-boundary
  # This sandbox-owned fixture MUST represent pre-identity retained state with a
  # nil Git snapshot. Only its ordinary operation enqueue tests physical-only
  # accounting; fixture insertion MUST NOT establish new public admission or
  # native guest acceptance.
  @spec retained_firmware_fixture(
          Host.t(),
          StoragePool.t(),
          Marshall.Accounts.User.t(),
          firmware_request()
        ) :: VirtualMachine.t()
  defp retained_firmware_fixture(host, pool, user, params) do
    {:ok, %VirtualMachine{} = vm} =
      Ledger.transaction(
        fn ->
          slot = AddressAllocation.next_slot!(params.profile)
          %Host{} = host = Ledger.lock!(Host, host.id)
          placement_id = Ash.UUID.generate()

          vm =
            Ledger.create!(
              VirtualMachine,
              :allocate,
              Map.merge(params, %{
                name: "retained-" <> Ash.UUID.generate(),
                owner_id: user.id,
                current_placement_id: placement_id,
                git_identity: nil
              })
            )

          Ledger.create!(WorkloadPlacement, :allocate, %{
            id: placement_id,
            vm_id: vm.id,
            host_id: host.id,
            pool_id: pool.id
          })

          Ledger.create!(
            Reservation,
            :reserve,
            Map.merge(OverallsProtocol.VMShape.reservation(params), %{
              vm_id: vm.id,
              placement_id: placement_id,
              host_id: host.id,
              pool_id: pool.id
            })
          )

          Ledger.create!(NetworkAddress, :reserve, %{
            vm_id: vm.id,
            profile: vm.profile,
            slot: slot
          })

          Ledger.create!(Operation, :enqueue, %{
            vm_id: vm.id,
            placement_id: placement_id,
            execution_epoch: vm.execution_epoch,
            requested_by_id: user.id,
            generation: vm.generation,
            kind: :provision
          })

          vm
        end,
        user
      )

    vm
  end
end
