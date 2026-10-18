defmodule OverallsProtocol.VMShape do
  @moduledoc "Shared execution limits and host reservation costs for the pinned VMM."
  @overhead 67_108_864
  @maximum_disk_bytes 536_870_912_000

  @spec checkpoint_bytes(pos_integer()) :: pos_integer()
  def checkpoint_bytes(memory_bytes), do: OverallsProtocol.Checkpoint.storage_bytes(memory_bytes)

  @spec maximum_disk_bytes() :: pos_integer()
  def maximum_disk_bytes, do: @maximum_disk_bytes

  @spec maximum_disk_gib() :: pos_integer()
  def maximum_disk_gib, do: div(@maximum_disk_bytes, 1_073_741_824)

  # @cc [owner:ghuntley,label:capacity] aligned-execution-shapes
  # valid?/3 MUST accept only 1..32 integer vCPUs, 512 MiB..256 GiB memory aligned to 1 MiB, and 2
  # GiB..500 GiB disk aligned to 4096 bytes; imprecise or unaligned sizes must fail validation.
  @spec valid?(term(), term(), term()) :: boolean()
  def valid?(cpu, memory, disk) do
    is_integer(cpu) and cpu in 1..32 and
      is_integer(memory) and memory in 536_870_912..274_877_906_944 and
      rem(memory, 1_048_576) == 0 and
      is_integer(disk) and disk in 2_147_483_648..@maximum_disk_bytes and rem(disk, 4096) == 0
  end

  # @cc [owner:ghuntley,label:capacity] guest-plus-vmm-reservation
  # host_memory/1 MUST add exactly 64 MiB to validated guest memory. Admission reservations and
  # host cgroup limits must use this same cost so the VMM allowance is neither omitted nor charged
  # twice.
  @spec host_memory(pos_integer()) :: pos_integer()
  def host_memory(guest_memory), do: guest_memory + @overhead

  # @cc [owner:ghuntley,label:capacity] portable-bundle-reservation
  # reservation/1 MUST charge the complete profile drive footprint plus the
  # fixed maximum portable kernel, initrd and metadata footprint. Admission,
  # cloning and relocation temporary holds use this same conservative cost.

  @spec reservation(map()) :: %{
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer()
        }
  def reservation(shape),
    do: %{
      vcpu: shape.vcpu,
      memory_bytes: host_memory(shape.memory_bytes),
      disk_bytes:
        OverallsProtocol.DiskLayout.bytes(Map.get(shape, :profile, :customer), shape.disk_bytes) +
          OverallsProtocol.WorkloadBundle.storage_bytes()
    }
end
