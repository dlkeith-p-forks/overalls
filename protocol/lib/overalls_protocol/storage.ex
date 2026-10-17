defmodule OverallsProtocol.Storage do
  @moduledoc "Explicit ZFS identity and physical observations; logical admission budgets belong to Marshall."
  @maximum 9_223_372_036_854_775_807
  @guid_maximum 18_446_744_073_709_551_615
  @type identity :: %{
          backend: :zfs,
          zpool_guid: String.t(),
          dataset_guid: String.t(),
          dataset: String.t()
        }
  @type wire_observation :: %{
          backend: :zfs,
          zpool_guid: String.t(),
          dataset_guid: String.t(),
          dataset: String.t(),
          used_bytes: non_neg_integer(),
          quota_bytes: pos_integer() | nil
        }
  @type observation :: %{
          backend: :zfs,
          zpool_guid: String.t(),
          dataset_guid: String.t(),
          dataset: String.t(),
          used_bytes: non_neg_integer(),
          logical_used_bytes: non_neg_integer(),
          quota_bytes: pos_integer() | nil,
          compression_ratio: number()
        }

  # @cc [owner:ghuntley,label:protocol;capacity] zfs-identity-exact-guid-binding
  # ZFS identities MUST contain a named child dataset and canonical unsigned
  # 64-bit pool/dataset GUID strings. Peer input MUST NOT create atoms or reuse
  # an ext4 filesystem identifier. Zpool identity is independent of dataset name.
  @spec identity(term()) :: {:ok, identity()} | :error
  def identity(
        %{"backend" => "zfs", "zpool_guid" => pool, "dataset_guid" => dataset, "dataset" => name} =
          value
      )
      when map_size(value) == 4 do
    decoded = %{backend: :zfs, zpool_guid: pool, dataset_guid: dataset, dataset: name}
    if valid_identity?(decoded), do: {:ok, decoded}, else: :error
  end

  def identity(_), do: :error

  @spec valid_identity?(term()) :: boolean()
  def valid_identity?(%{backend: :zfs, zpool_guid: pool, dataset_guid: dataset, dataset: name}) do
    guid?(pool) and guid?(dataset) and is_binary(name) and byte_size(name) <= 240 and
      Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_.-]*(\/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+\z/, name)
  end

  def valid_identity?(_), do: false

  @spec filesystem_id(identity()) :: String.t()
  def filesystem_id(identity), do: "zfs:" <> identity.zpool_guid <> ":" <> identity.dataset_guid

  @spec observation(term()) :: {:ok, wire_observation()} | :error
  def observation(
        %{
          "backend" => "zfs",
          "zpool_guid" => pool,
          "dataset_guid" => dataset,
          "dataset" => name,
          "used_bytes" => used,
          "quota_bytes" => quota
        } = value
      )
      when map_size(value) == 6 do
    decoded = %{
      backend: :zfs,
      zpool_guid: pool,
      dataset_guid: dataset,
      dataset: name,
      used_bytes: used,
      quota_bytes: quota
    }

    if valid_observation?(decoded), do: {:ok, decoded}, else: :error
  end

  def observation(_), do: :error

  # @cc [owner:ghuntley,label:capacity] zfs-physical-accounting-is-not-logical-credit
  # Observations MUST bound physical/logical byte counts independently and keep
  # absent quotas unknown. Compression ratios and logical usage MUST NOT become
  # physical allocation credit or change an enrolled logical admission budget.
  @spec valid_observation?(term()) :: boolean()
  def valid_observation?(
        %{
          used_bytes: used,
          quota_bytes: quota
        } = value
      )
      when map_size(value) in [6, 8] do
    valid_identity?(value) and bytes?(used) and
      (is_nil(quota) or (bytes?(quota) and quota > 0 and used <= quota)) and
      local_diagnostics?(value)
  end

  def valid_observation?(_), do: false

  @spec local_diagnostics?(map()) :: boolean()
  defp local_diagnostics?(%{logical_used_bytes: logical, compression_ratio: ratio}),
    do: bytes?(logical) and is_number(ratio) and ratio > 0 and ratio <= 1_000_000

  defp local_diagnostics?(value), do: map_size(value) == 6

  @spec coherent?(term(), non_neg_integer(), non_neg_integer()) :: boolean()
  def coherent?(observation, total, free) do
    valid_observation?(observation) and observation.used_bytes == total - free and
      (is_nil(observation.quota_bytes) or total <= observation.quota_bytes)
  end

  @spec encode(identity() | observation() | wire_observation()) :: map()
  def encode(value) do
    value
    |> Map.drop([:logical_used_bytes, :compression_ratio])
    |> Map.new(fn
      {:backend, :zfs} -> {"backend", "zfs"}
      {key, item} -> {Atom.to_string(key), item}
    end)
  end

  @doc "Whether a value is a canonical, nonzero unsigned 64-bit ZFS GUID string."
  @spec guid?(term()) :: boolean()
  def guid?(value) when is_binary(value) and byte_size(value) in 1..20 do
    Regex.match?(~r/\A[1-9][0-9]*\z/, value) and String.to_integer(value) <= @guid_maximum
  end

  def guid?(_), do: false
  defp bytes?(value), do: is_integer(value) and value >= 0 and value <= @maximum
end
