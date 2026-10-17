defmodule OverallsProtocol.DiskTransfer do
  @moduledoc "Validated portable disk descriptors; copying never grants VM execution authority."
  alias OverallsProtocol.{Execution, Relocation, Storage}
  @type intent :: map()
  @type descriptor :: map()

  # @cc [owner:ghuntley,label:security;protocol] clone-transfer-distinct-identities
  # Clone descriptors MUST bind distinct VM and placement identities and independent
  # addresses. Source and destination may share a host/pool. The single dataset
  # stream MUST carry every profile-derived drive of the bound workload, including
  # Inception's additional data drive. Clone epochs are independent. A clone
  # descriptor MUST NOT validate as relocation.
  @spec intent(term()) :: {:ok, intent()} | {:error, atom()}
  def intent(%{"purpose" => "clone", "version" => 3} = wire) when map_size(wire) == 11 do
    with true <- OverallsProtocol.uuid?(wire["relocation_id"]),
         true <- OverallsProtocol.uuid?(wire["destination_vm_id"]),
         {:ok, source} <- command(wire, "source"),
         {:ok, destination} <- command(wire, "destination"),
         true <-
           source.vm_id != destination.vm_id and source.placement_id != destination.placement_id,
         true <- source.slot != destination.slot do
      {:ok,
       %{
         purpose: :clone,
         relocation_id: wire["relocation_id"],
         vm_id: source.vm_id,
         destination_vm_id: destination.vm_id,
         source_slot: source.slot,
         source: Map.take(source, [:placement_id, :host_id, :pool_id]),
         destination: Map.take(destination, [:placement_id, :host_id, :pool_id]),
         source_epoch: source.execution_epoch,
         destination_epoch: destination.execution_epoch,
         workload:
           Map.take(destination, [
             :image_id,
             :architecture,
             :profile,
             :slot,
             :vcpu,
             :memory_bytes,
             :disk_bytes
           ])
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def intent(%{"purpose" => _}), do: {:error, :invalid_message}
  def intent(wire), do: Relocation.intent(wire)

  @spec descriptor(term()) :: {:ok, descriptor()} | {:error, atom()}
  def descriptor(%{"purpose" => "clone", "stream" => stream} = wire) when map_size(wire) == 12 do
    with {:ok, intent} <- intent(Map.delete(wire, "stream")),
         %{"source_dataset_guid" => dataset, "to_guid" => guid} <- stream,
         true <- map_size(stream) == 2 and Storage.guid?(dataset) and Storage.guid?(guid),
         do: {:ok, Map.put(intent, :stream, %{source_dataset_guid: dataset, to_guid: guid})},
         else: (_ -> {:error, :invalid_message})
  end

  def descriptor(%{"purpose" => _}), do: {:error, :invalid_message}
  def descriptor(wire), do: Relocation.descriptor(wire)

  @spec encode_intent(intent()) :: map()
  def encode_intent(%{purpose: :clone} = intent),
    do: intent |> Map.delete(:stream) |> wire() |> Map.put("version", 3)

  def encode_intent(intent), do: Relocation.encode_intent(intent)

  @spec encode_descriptor(descriptor()) :: map()
  def encode_descriptor(%{purpose: :clone} = descriptor),
    do: descriptor |> wire() |> Map.put("version", 3)

  def encode_descriptor(descriptor), do: Relocation.encode_descriptor(descriptor)

  @spec source_workload(intent()) :: map()
  def source_workload(%{purpose: :clone} = descriptor),
    do: Map.put(descriptor.workload, :slot, descriptor.source_slot)

  def source_workload(descriptor), do: descriptor.workload

  defp command(wire, endpoint) do
    value = wire[endpoint]
    workload = wire["workload"]

    if is_map(value) and map_size(value) == 3 and is_map(workload) and map_size(workload) == 7 do
      attrs = Map.merge(workload, value)

      attrs =
        Map.merge(attrs, %{
          "id" => wire["relocation_id"],
          "generation" => 1,
          "kind" => "stop",
          "vm_id" => if(endpoint == "source", do: wire["vm_id"], else: wire["destination_vm_id"]),
          "execution_epoch" => wire[endpoint <> "_epoch"]
        })

      attrs =
        if endpoint == "source", do: Map.put(attrs, "slot", wire["source_slot"]), else: attrs

      Execution.placement_command(attrs)
    else
      {:error, :invalid_message}
    end
  end

  defp wire(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {Atom.to_string(key), wire(item)} end)

  defp wire(nil), do: nil
  defp wire(value) when is_atom(value), do: Atom.to_string(value)
  defp wire(value), do: value
end
