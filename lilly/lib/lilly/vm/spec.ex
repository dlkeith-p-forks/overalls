defmodule Lilly.VM.Spec do
  @moduledoc "Validated local execution shape; id identifies the physical placement for v4 commands."
  alias Lilly.Network.Guest
  @enforce_keys [:id, :image_id, :pool_id, :network, :vcpu, :memory_bytes, :disk_bytes]
  defstruct [
    :id,
    :image_id,
    :pool_id,
    :network,
    :vcpu,
    :memory_bytes,
    :disk_bytes,
    workspace_source: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          image_id: String.t(),
          pool_id: String.t(),
          network: Guest.t(),
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer(),
          workspace_source: OverallsProtocol.WorkspaceSource.t() | nil
        }

  # @cc [owner:ghuntley,label:security] local-spec-validates-before-effects
  # Spec.new/1 MUST reject extra or missing fields, invalid image/pool/guest identities and
  # unaligned resource sizes before returning a shape suitable for privileged execution.

  # @cc [owner:ghuntley,label:recovery;security] spec-workspace-source-not-persisted
  # An optional workspace_source MUST be a valid closed source-v2 provider reference and MUST NOT
  # enter encode/1: persisted disk, dataset and backup identities stay byte-identical
  # whether or not a command carries a source, so old metadata keeps matching (ADR-0128).
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_vm_specification}
  def new(%{workspace_source: source} = value) when map_size(value) == 9 do
    with true <- OverallsProtocol.WorkspaceSource.valid?(source),
         {:ok, spec} <- new(Map.delete(value, :workspace_source)) do
      {:ok, %{spec | workspace_source: source}}
    else
      _ -> {:error, :invalid_vm_specification}
    end
  end

  def new(
        %{
          id: id,
          image_id: image,
          pool_id: pool,
          profile: profile,
          slot: slot,
          vcpu: cpu,
          memory_bytes: memory,
          disk_bytes: disk
        } = value
      )
      when map_size(value) == 8 do
    with true <- OverallsProtocol.uuid?(pool) and OverallsProtocol.ImageManifest.id?(image),
         {:ok, network} <- Guest.new(id, profile, slot),
         true <- OverallsProtocol.VMShape.valid?(cpu, memory, disk) do
      {:ok,
       %__MODULE__{
         id: id,
         image_id: image,
         pool_id: pool,
         network: network,
         vcpu: cpu,
         memory_bytes: memory,
         disk_bytes: disk
       }}
    else
      _ -> {:error, :invalid_vm_specification}
    end
  end

  def new(_), do: {:error, :invalid_vm_specification}

  @doc "The execution coordinator must reserve this host memory, including VMM overhead."
  @spec host_memory(t()) :: pos_integer()
  def host_memory(spec), do: OverallsProtocol.VMShape.host_memory(spec.memory_bytes)

  @spec drives(t()) :: [OverallsProtocol.DiskLayout.drive()]
  def drives(spec), do: OverallsProtocol.DiskLayout.drives(spec.network.profile, spec.disk_bytes)

  @spec storage_bytes(t()) :: pos_integer()
  def storage_bytes(spec),
    do:
      OverallsProtocol.DiskLayout.bytes(spec.network.profile, spec.disk_bytes) +
        OverallsProtocol.WorkloadBundle.storage_bytes()

  # @cc [owner:ghuntley,label:recovery;security] spec-storage-shape-ignores-delivery
  # storage/1 MUST return the persisted dataset identity of a spec: the exact
  # shape with its guest-delivery workspace source cleared. Claim, snapshot and
  # adoption comparisons MUST compare this shape, never the full struct, so a
  # start command that carries a source still matches the claim its stopped
  # or provisioning predecessor journaled (ADR-0128).
  @spec storage(t()) :: t()
  def storage(spec), do: %{spec | workspace_source: nil}

  @spec encode(t()) :: map()
  def encode(spec),
    do: %{
      "id" => spec.id,
      "image_id" => spec.image_id,
      "pool_id" => spec.pool_id,
      "profile" => Atom.to_string(spec.network.profile),
      "slot" => spec.network.slot,
      "vcpu" => spec.vcpu,
      "memory_bytes" => spec.memory_bytes,
      "disk_bytes" => spec.disk_bytes
    }
end
