defmodule GitHubHistoricalFleet do
  @moduledoc "Disposable historical allocation setup; real provisioning supplies all physical facts."
  alias Marshall.Compute.{
    AddressAllocation,
    Budget,
    Host,
    HostLiveness,
    Image,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    StoragePool,
    VirtualMachine,
    WorkloadPlacement
  }

  # @cc [owner:ghuntley,label:verification;security;capacity] github-historical-windows-allocation
  # Only the explicit historical Windows composition and synthetic owner may
  # allocate the exact frozen image without a new Git-identity snapshot. Setup
  # MUST retain measured capacity, address/reservation ownership, agent roots and
  # the real provision operation. No disk, observed state, readiness, executor,
  # OAuth grant or maintenance outcome may be fabricated. This is historical
  # allocation simulation, never new-UI admission or retained-user-data evidence.
  @spec run(map()) :: map()
  def run(%{
        "owner_id" => owner,
        "host_id" => host_id,
        "pool_id" => pool_id,
        "image_id" => image_id,
        "key" => key
      }) do
    "1" = System.fetch_env!("FLEET_GITHUB_HISTORICAL_WINDOWS")
    true = Enum.all?([owner, host_id, pool_id, key], &OverallsProtocol.uuid?/1)
    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)
    true = String.ends_with?(to_string(actor.email), "@example.test")
    false = actor.administrator

    {:ok, frozen} =
      System.fetch_env!("FLEET_GUEST")
      |> Path.join("manifest.json")
      |> File.read!()
      |> JSON.decode!()
      |> OverallsProtocol.ImageManifest.validate()

    ^image_id = frozen.id
    true = OverallsProtocol.NativeAdmission.admitted?(frozen)
    false = Map.has_key?(frozen, :git_identity_version)
    true = OverallsProtocol.ImageManifest.guest_agents(frozen) == :windows_v1

    {:ok, result} =
      Ledger.transaction(fn ->
        [image] = Ledger.read!(Image, id: image_id)
        true = image.manifest["guest_agents"] == "windows-v1"

        shape = %{
          architecture: :x86_64,
          profile: :oss,
          vcpu: 2,
          memory_bytes: image.minimum_memory_bytes,
          disk_bytes: image.minimum_disk_bytes
        }

        needed = OverallsProtocol.VMShape.reservation(shape)
        slot = AddressAllocation.next_slot!(:oss)
        host = Ledger.lock!(Host, host_id)
        pool = Ledger.lock!(StoragePool, pool_id)
        ^host_id = pool.host_id
        true = host.enabled and host.maintenance_mode == :normal
        true = host.inventory["execution_ready"] == true
        true = image_id in host.inventory["images"]
        true = HostLiveness.capacity_fresh?(host.reported_at, Ledger.now())
        true = HostLiveness.capacity_fresh?(pool.reported_at, Ledger.now())

        true =
          Budget.fits?(
            Budget.available(host, pool, Ledger.read!(Reservation, host_id: host_id)),
            needed
          )

        placement_id = Ash.UUID.generate()

        vm =
          Ledger.create!(
            VirtualMachine,
            :allocate,
            Map.merge(shape, %{
              id: Ash.UUID.generate(),
              name: "github-historical-" <> binary_part(owner, 0, 8),
              owner_id: owner,
              image_id: image_id,
              idempotency_key: key,
              current_placement_id: placement_id,
              git_identity: nil
            })
          )

        Marshall.Agents.Registration.register!(vm)
        Marshall.Ingress.Endpoints.ensure!(vm)

        Ledger.create!(WorkloadPlacement, :allocate, %{
          id: placement_id,
          vm_id: vm.id,
          host_id: host_id,
          pool_id: pool_id
        })

        Ledger.create!(
          Reservation,
          :reserve,
          Map.merge(
            needed,
            %{vm_id: vm.id, placement_id: placement_id, host_id: host_id, pool_id: pool_id}
          )
        )

        Ledger.create!(NetworkAddress, :reserve, %{vm_id: vm.id, profile: :oss, slot: slot})

        Ledger.create!(Operation, :enqueue, %{
          placement_id: placement_id,
          execution_epoch: vm.execution_epoch,
          vm_id: vm.id,
          requested_by_id: actor.id,
          generation: vm.generation,
          kind: :provision
        })

        %{vm_id: vm.id, placement_id: placement_id, historical_setup: true}
      end)

    result
  end
end
