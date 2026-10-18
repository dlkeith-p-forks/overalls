defmodule OverallsProtocol.Relocation do
  @moduledoc """
  Closed v3 relocation descriptors. A descriptor identifies portable disk
  content, optional immutable RAM and its endpoints; it is neither an SSH permit nor execution authority.
  Dataset paths and host-local ownership records are deliberately absent.
  """

  alias OverallsProtocol.{ImageManifest, Storage, VMShape}

  @maximum 9_223_372_036_854_775_807
  @type endpoint :: %{
          placement_id: OverallsProtocol.uuid(),
          host_id: OverallsProtocol.uuid(),
          pool_id: OverallsProtocol.uuid()
        }
  @type workload :: %{
          image_id: String.t(),
          architecture: :x86_64,
          profile: :customer | :standard | :oss | :inception,
          slot: pos_integer(),
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer()
        }
  @type stream :: %{source_dataset_guid: String.t(), to_guid: String.t()}
  @type descriptor :: %{
          optional(:checkpoint) => OverallsProtocol.Checkpoint.t(),
          relocation_id: OverallsProtocol.uuid(),
          vm_id: OverallsProtocol.uuid(),
          source: endpoint(),
          destination: endpoint(),
          source_epoch: pos_integer(),
          destination_epoch: pos_integer(),
          workload: workload(),
          stream: stream()
        }
  @type failure :: {:error, :invalid_message | :unsupported_version}
  @type intent :: %{
          optional(:checkpoint) => OverallsProtocol.Checkpoint.t(),
          relocation_id: OverallsProtocol.uuid(),
          vm_id: OverallsProtocol.uuid(),
          source: endpoint(),
          destination: endpoint(),
          source_epoch: pos_integer(),
          destination_epoch: pos_integer(),
          workload: workload()
        }

  # @cc [owner:ghuntley,label:protocol;security] relocation-descriptor-is-not-execution
  # descriptor/1 MUST accept only the closed v3 descriptor, with distinct
  # source/destination placement, host and pool IDs and exactly one epoch advance.
  # Paths, execution commands, credentials and extra fields MUST be rejected.
  # Consumers MUST separately authorize transfer and activation; valid syntax
  # does not establish current ownership, permission or snapshot existence.
  @spec descriptor(term()) :: {:ok, descriptor()} | failure()
  def descriptor(%{"checkpoint" => checkpoint} = value) do
    with {:ok, checkpoint} <- OverallsProtocol.Checkpoint.decode(checkpoint),
         {:ok, descriptor} <- descriptor(Map.delete(value, "checkpoint")),
         true <- checkpoint.memory_bytes == descriptor.workload.memory_bytes do
      {:ok, Map.put(descriptor, :checkpoint, checkpoint)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def descriptor(%{"version" => 3, "stream" => stream} = value) when map_size(value) == 9 do
    with {:ok, intent} <- intent(Map.delete(value, "stream")),
         {:ok, stream} <- stream(stream),
         do: {:ok, Map.put(intent, :stream, stream)},
         else: (_ -> {:error, :invalid_message})
  end

  def descriptor(%{"version" => version}) when version != 3,
    do: {:error, :unsupported_version}

  def descriptor(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:protocol;security] relocation-intent-has-no-invented-lineage
  # intent/1 MUST validate the same immutable endpoints, workload and successor
  # epoch as a descriptor, without accepting a stream or fabricating GUIDs for
  # snapshots not yet observed. Intent alone MUST NOT authorize execution.
  @spec intent(term()) :: {:ok, intent()} | failure()
  def intent(%{"checkpoint" => checkpoint} = value) do
    with {:ok, checkpoint} <- OverallsProtocol.Checkpoint.decode(checkpoint),
         {:ok, intent} <- intent(Map.delete(value, "checkpoint")),
         true <- checkpoint.memory_bytes == intent.workload.memory_bytes do
      {:ok, Map.put(intent, :checkpoint, checkpoint)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def intent(
        %{
          "version" => 3,
          "relocation_id" => relocation,
          "vm_id" => vm,
          "source" => source,
          "destination" => destination,
          "source_epoch" => source_epoch,
          "destination_epoch" => destination_epoch,
          "workload" => workload
        } = value
      )
      when map_size(value) == 8 do
    with true <- OverallsProtocol.uuid?(relocation) and OverallsProtocol.uuid?(vm),
         true <- is_integer(source_epoch) and source_epoch in 1..(@maximum - 1),
         true <- is_integer(destination_epoch) and destination_epoch == source_epoch + 1,
         {:ok, source} <- endpoint(source),
         {:ok, destination} <- endpoint(destination),
         true <- Enum.all?([:placement_id, :host_id, :pool_id], &(source[&1] != destination[&1])),
         {:ok, workload} <- workload(workload) do
      {:ok,
       %{
         relocation_id: relocation,
         vm_id: vm,
         source: source,
         destination: destination,
         source_epoch: source_epoch,
         destination_epoch: destination_epoch,
         workload: workload
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def intent(%{"version" => version}) when version != 3,
    do: {:error, :unsupported_version}

  def intent(_), do: {:error, :invalid_message}

  @spec encode_intent(intent()) :: map()
  def encode_intent(value), do: value |> encode() |> Map.put("version", 3)

  @spec encode_descriptor(descriptor()) :: map()
  def encode_descriptor(value), do: value |> encode() |> Map.put("version", 3)

  defp endpoint(%{"placement_id" => placement, "host_id" => host, "pool_id" => pool} = value)
       when map_size(value) == 3 do
    if Enum.all?([placement, host, pool], &OverallsProtocol.uuid?/1),
      do: {:ok, %{placement_id: placement, host_id: host, pool_id: pool}},
      else: :error
  end

  defp endpoint(_), do: :error

  defp workload(
         %{
           "image_id" => image,
           "architecture" => "x86_64",
           "profile" => profile,
           "slot" => slot,
           "vcpu" => cpu,
           "memory_bytes" => memory,
           "disk_bytes" => disk
         } = value
       )
       when map_size(value) == 7 do
    with true <- ImageManifest.id?(image) and VMShape.valid?(cpu, memory, disk),
         true <- is_integer(slot) and slot in 2..65534,
         {:ok, profile} <- enum(profile, [:customer, :standard, :oss, :inception]) do
      {:ok,
       %{
         image_id: image,
         architecture: :x86_64,
         profile: profile,
         slot: slot,
         vcpu: cpu,
         memory_bytes: memory,
         disk_bytes: disk
       }}
    else
      _ -> :error
    end
  end

  defp workload(_), do: :error

  # @cc [owner:ghuntley,label:protocol;recovery] relocation-stream-lineage
  # A stream is always one full send of the single owned transfer snapshot
  # (ADR-0155): it carries no kind and no parent GUID. Every stream MUST bind the
  # source dataset GUID, which the exporter MUST verify against its local
  # ownership claim, and the snapshot GUID. The receiver MUST verify that GUID
  # against received ZFS state and bind its own local filesystem GUID; source
  # filesystem GUID equality MUST NOT be required at the destination. Syntax
  # alone never proves successful transfer.
  defp stream(%{"source_dataset_guid" => dataset, "to_guid" => to} = value)
       when map_size(value) == 2 do
    if Storage.guid?(dataset) and Storage.guid?(to),
      do: {:ok, %{source_dataset_guid: dataset, to_guid: to}},
      else: :error
  end

  defp stream(_), do: :error

  defp enum(value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp encode(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {Atom.to_string(key), encode(item)} end)

  defp encode(nil), do: nil
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(value), do: value
end
