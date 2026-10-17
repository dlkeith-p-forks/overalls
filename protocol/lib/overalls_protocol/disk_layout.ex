defmodule OverallsProtocol.DiskLayout do
  @moduledoc """
  Profile-owned persistent drives. disk_bytes describes the root drive, whose
  slot is always named rootfs.ext4 whatever the image root format.
  """
  @inception_data_bytes 274_877_906_944

  @type drive :: %{name: String.t(), bytes: pos_integer(), root: boolean()}

  # @cc [owner:ghuntley,label:storage] inception-fixed-additional-drive
  # drives/2 MUST retain the requested root size and add exactly one separate 256 GiB
  # data.raw drive only for Inception. Drive names and ordering MUST remain stable
  # across restarts, with the root drive slot `rootfs.ext4` first regardless of the image
  # root format. Callers MUST supply a validated profile
  # and root size; guest or peer input MUST NOT choose filesystem paths.
  @spec drives(OverallsProtocol.AddressPool.profile(), pos_integer()) :: [drive()]
  def drives(profile, root_bytes)
      when profile in [:customer, :standard, :oss, :inception] and
             is_integer(root_bytes) and root_bytes > 0 do
    root = %{name: "rootfs.ext4", bytes: root_bytes, root: true}

    if profile == :inception,
      do: [root, %{name: "data.raw", bytes: @inception_data_bytes, root: false}],
      else: [root]
  end

  # @cc [owner:ghuntley,label:capacity] persistent-drive-total
  # bytes/2 MUST charge the logical size of every drive exactly once, including the
  # Inception data disk. This sum MUST NOT be treated as physical allocated usage.
  @spec bytes(OverallsProtocol.AddressPool.profile(), pos_integer()) :: pos_integer()
  def bytes(profile, root_bytes), do: Enum.sum(Enum.map(drives(profile, root_bytes), & &1.bytes))
end
