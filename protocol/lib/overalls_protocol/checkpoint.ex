defmodule OverallsProtocol.Checkpoint do
  @moduledoc "Closed, inert identity of an immutable memory continuation."
  @overhead 67_108_864
  @keys ~w(id memory_bytes state_bytes compatibility memory_sha256 state_sha256 manifest_sha256 dataset_guid snapshot_guid)
  @type t :: %{
          id: OverallsProtocol.uuid(),
          memory_bytes: pos_integer(),
          state_bytes: pos_integer(),
          compatibility: String.t(),
          memory_sha256: String.t(),
          state_sha256: String.t(),
          manifest_sha256: String.t(),
          dataset_guid: String.t(),
          snapshot_guid: String.t()
        }

  @spec overhead_bytes() :: pos_integer()
  def overhead_bytes, do: @overhead

  @spec storage_bytes(pos_integer()) :: pos_integer()
  def storage_bytes(memory_bytes), do: memory_bytes + @overhead

  # @cc [owner:ghuntley,label:security;protocol;recovery] checkpoint-is-inert-content-identity
  # decode/1 MUST accept only the closed bounded content identity of a full RAM
  # checkpoint. It MUST NOT accept host paths, boot credentials or execution
  # authority. A valid descriptor alone never authorizes loading its memory.
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_checkpoint}
  def decode(value) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         true <- OverallsProtocol.uuid?(value["id"]),
         memory = value["memory_bytes"],
         true <- is_integer(memory) and memory in 536_870_912..274_877_906_944,
         true <- rem(memory, 1_048_576) == 0,
         state = value["state_bytes"],
         true <- is_integer(state) and state in 1..(@overhead - 65_536),
         true <-
           Enum.all?(~w(compatibility memory_sha256 state_sha256 manifest_sha256), fn key ->
             OverallsProtocol.ImageManifest.id?(value[key])
           end),
         true <-
           Enum.all?(~w(dataset_guid snapshot_guid), &OverallsProtocol.Storage.guid?(value[&1])) do
      {:ok,
       %{
         id: value["id"],
         memory_bytes: memory,
         state_bytes: state,
         compatibility: value["compatibility"],
         memory_sha256: value["memory_sha256"],
         state_sha256: value["state_sha256"],
         manifest_sha256: value["manifest_sha256"],
         dataset_guid: value["dataset_guid"],
         snapshot_guid: value["snapshot_guid"]
       }}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def decode(_), do: {:error, :invalid_checkpoint}

  @spec encode(t()) :: map()
  def encode(checkpoint),
    do: Map.new(checkpoint, fn {key, value} -> {Atom.to_string(key), value} end)
end
