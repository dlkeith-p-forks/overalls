defmodule Lilly.VM.TrustStageTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Lilly.VM.Driver

  @spec fixture([binary()]) :: {Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.VM.Spec.t()}
  defp fixture(roots) do
    placement = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Config.new(Lilly.UUID.generate(), "eth0", [], "/tmp/net")
    {:ok, guest} = Lilly.Network.Guest.new(placement, :customer, 2)

    config = %Lilly.VM.Config{
      state_dir: "/tmp/vms",
      network: network,
      firecracker: "/tools/firecracker",
      jailer: "/tools/jailer",
      unshare: "/tools/unshare",
      launch_guard: "/tools/guard",
      boot_log_writer: "/tools/boot-log",
      guest_trust_roots: roots
    }

    spec = %Lilly.VM.Spec{
      id: placement,
      image_id: "fixture",
      pool_id: Lilly.UUID.generate(),
      network: guest,
      vcpu: 2,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }

    pool = %Lilly.Host.Pool{id: spec.pool_id, path: "/tmp/pool", filesystem_id: "fixture"}
    {config, pool, spec}
  end

  # @cc [owner:ghuntley,label:verification;observability] trust-stage-closed-set
  # Whatever revision is asked for, trust/4 without a valid boot bundle MUST
  # return trust_boot_unconfirmed before any placement mutation or delivery,
  # a member of trust_stages/0,
  # never the former collapsed trust_unconfirmed atom; with no trust roots it
  # MUST succeed without touching the placement.
  property "unconfirmed trust always names a closed stage" do
    check all(
            epoch <- positive_integer(),
            generation <- positive_integer(),
            roots <- list_of(string(:printable, min_length: 1), min_length: 1, max_length: 3)
          ) do
      {config, pool, spec} = fixture(roots)
      options = [execution_epoch: epoch, generation: generation, vm_id: spec.id]

      assert {:error, :trust_boot_unconfirmed} = Driver.trust(config, pool, spec, options)
      assert :trust_boot_unconfirmed in Driver.trust_stages()
      refute :trust_unconfirmed in Driver.trust_stages()

      {untrusted, pool, spec} = fixture([])
      assert :ok = Driver.trust(untrusted, pool, spec, options)
    end
  end
end
