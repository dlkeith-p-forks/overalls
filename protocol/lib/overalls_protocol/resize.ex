defmodule OverallsProtocol.Resize do
  @moduledoc "Closed resource transitions for an existing stopped placement."
  @fields [:vcpu, :memory_bytes, :disk_bytes]

  @spec sizes(map()) :: map()
  def sizes(value), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(value, &1)})

  @spec valid_sizes?(term()) :: boolean()
  def valid_sizes?(%{"vcpu" => cpu, "memory_bytes" => memory, "disk_bytes" => disk} = sizes)
      when map_size(sizes) == 3, do: OverallsProtocol.VMShape.valid?(cpu, memory, disk)

  def valid_sizes?(_), do: false

  # @cc [owner:ghuntley,label:recovery] resize-never-shrinks-disk
  # A transition MUST validate both complete shapes and reject any disk decrease.
  # CPU and memory may decrease without altering other workload identity fields.
  @spec valid_transition?(term(), map()) :: boolean()
  def valid_transition?(source, target) do
    valid_sizes?(source) and valid_sizes?(sizes(target)) and
      target.disk_bytes >= source["disk_bytes"]
  end
end
