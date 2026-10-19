defmodule LocalizationPackagedFixture do
  alias Marshall.Compute.{Host, HostReports, Images, Ledger, StoragePool}

  # @cc [owner:ghuntley,label:security;verification] packaged-localization-fixture
  # Only disposable ordinary users MAY be seeded. Login tokens MUST remain in
  # owner-private VM files. Tested locale mutation MUST retain normal authority.
  @spec run() :: :ok
  def run do
    {:ok, _} = Application.ensure_all_started(:marshall)

    [bootstrap] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

    Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})
    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "language-owner@example.test"})
    Ash.Seed.seed!(Marshall.Accounts.User, %{email: "language-foreign@example.test"})
    [machine | _] = machines(owner)
    File.write!("/run/overalls-test/localization-machine", machine)
    File.chmod!("/run/overalls-test/localization-machine", 0o600)
    public = "/run/overalls-test/localization-key.pub" |> File.read!() |> String.trim()
    {:ok, _} = Marshall.SSH.add_key(%{public_key: public}, actor: owner)
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)
    File.write!("/run/overalls-test/localization-login", token)
    File.chmod!("/run/overalls-test/localization-login", 0o600)
    {:ok, _} = Marshall.Operations.SSHGateway.prepare("/run/overalls-test/gateway.token")

    {:ok, _} =
      Marshall.Operations.SSHGateway.configure("localization", "/run/overalls-test/gateway.token")

    :ok
  end

  # @cc [owner:ghuntley,label:verification] localization-synthetic-machine-scope
  # Synthetic artifact and host observations MAY support ordinary authorized
  # provisioning and browser pin/clone-form checks. They MUST NOT establish a
  # guest boot, filesystem, Lilly authority or physical isolation result.
  @spec machines(Marshall.Accounts.User.t()) :: [String.t()]
  defp machines(owner) do
    artifact = %{"bytes" => 16, "sha256" => String.duplicate("a", 64)}

    {:ok, image} =
      Images.register(
        %{
          "version" => 4,
          "architecture" => "x86_64",
          "workspace_source_version" => 2,
          "git_identity_version" => 1,
          "boot_args" => "console=ttyS0",
          "kernel" => artifact,
          "initrd" => artifact,
          "rootfs" => artifact,
          "minimum_memory_bytes" => 536_870_912,
          "minimum_disk_bytes" => 2_147_483_648
        },
        "synthetic-localization-fixture"
      )

    host =
      Ledger.create!(Host, :enroll, %{
        name: "localization-fixture",
        architecture: :x86_64,
        machine_id: "sha256:" <> String.duplicate("b", 64),
        overhead_cores: 1,
        overhead_memory_bytes: 1_073_741_824,
        transfer_endpoint: %{
          "address" => "localization.example.test",
          "port" => 2222,
          "host_key" => "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
        }
      })

    pool =
      Ledger.create!(StoragePool, :enroll, %{
        host_id: host.id,
        name: "guests",
        backend: :zfs,
        zpool_guid: "1",
        dataset_guid: "2",
        dataset: "fixture/localization",
        filesystem_id: "zfs:1:2",
        overhead_bytes: 1_073_741_824
      })

    Ledger.update!(host, :configure, %{enabled: true})
    {:ok, epoch} = HostReports.connect(host.id)
    {:ok, :ok} = HostReports.ingest(host.id, epoch, report(pool, image.id))

    for _ <- 1..2 do
      {:ok, vm} =
        Marshall.Compute.provision(
          %{
            idempotency_key: Ash.UUID.generate(),
            architecture: :x86_64,
            image_id: image.id,
            profile: :standard,
            vcpu: 1,
            memory_bytes: 536_870_912,
            disk_bytes: 2_147_483_648
          },
          actor: owner
        )

      vm = Ledger.intent!(vm, %{desired_state: :stopped, generation: vm.generation + 1})
      Ledger.update!(vm, :observe, %{observed_state: :stopped, observed_at: Ledger.now()})
      vm.id
    end
  end

  @spec report(StoragePool.t(), String.t()) :: HostReports.report()
  defp report(pool, image_id) do
    %{
      sequence: 1,
      sampled_at: Ledger.now(),
      effective_cores: 5,
      effective_memory_bytes: 4_294_967_296,
      inventory: %{
        "checkpoint_compatibility" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "images" => [image_id],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 5000,
        "memory_headroom_bytes" => 4_294_967_296,
        "interval_us" => 1_000_000,
        "covered" => %{}
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: 10_737_418_240,
          free_bytes: 10_737_418_240,
          allocations: %{},
          checkpoint_allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: "1",
            dataset_guid: "2",
            dataset: "fixture/localization",
            used_bytes: 0,
            quota_bytes: 10_737_418_240
          }
        }
      ]
    }
  end
end

LocalizationPackagedFixture.run()
