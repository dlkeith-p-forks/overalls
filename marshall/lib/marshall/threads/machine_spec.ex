defmodule Marshall.Threads.MachineSpec do
  @moduledoc "Typed machine admission settings retained by a user-facing thread."

  @type t :: %{
          architecture: :x86_64,
          image_id: String.t(),
          profile: :customer | :standard | :oss | :inception,
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer(),
          team_id: String.t() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(input) when is_map(input) do
    with {:ok, architecture} <- parse_architecture(input),
         {:ok, profile} <- parse_profile(Map.get(input, :profile, Map.get(input, "profile"))),
         {:ok, image_id} <- required_string(input, :image_id),
         {:ok, vcpu} <- positive_integer(input, :vcpu),
         {:ok, memory_bytes} <- positive_integer(input, :memory_bytes),
         {:ok, disk_bytes} <- positive_integer(input, :disk_bytes),
         {:ok, team_id} <- optional_uuid(input, :team_id),
         :ok <- validate_shape(architecture, profile, vcpu, memory_bytes, disk_bytes) do
      {:ok,
       %{
         architecture: architecture,
         image_id: image_id,
         profile: profile,
         vcpu: vcpu,
         memory_bytes: memory_bytes,
         disk_bytes: disk_bytes,
         team_id: team_id
       }}
    end
  end

  def from_map(_), do: {:error, :invalid_machine_spec}

  @spec to_map(t()) :: map()
  def to_map(spec), do: spec

  defp parse_architecture(input) do
    case Map.get(input, :architecture, Map.get(input, "architecture", :x86_64)) do
      architecture when architecture in [:x86_64, "x86_64"] -> {:ok, :x86_64}
      _ -> {:error, :invalid_machine_spec}
    end
  end

  defp parse_profile(profile) when profile in [:customer, :standard, :oss, :inception],
    do: {:ok, profile}

  defp parse_profile(profile) when profile in ["customer", "standard", "oss", "inception"],
    do: {:ok, String.to_existing_atom(profile)}

  defp parse_profile(_), do: {:error, :invalid_profile}

  # User threads always bind an agent root. Customer machines intentionally do
  # not expose the agent runtime, so accepting this profile would orphan the VM.
  defp validate_shape(:x86_64, :customer, _vcpu, _memory_bytes, _disk_bytes),
    do: {:error, :invalid_profile}

  defp validate_shape(:x86_64, _profile, vcpu, memory_bytes, disk_bytes) do
    if OverallsProtocol.VMShape.valid?(vcpu, memory_bytes, disk_bytes),
      do: :ok,
      else: {:error, :invalid_machine_spec}
  end

  defp required_string(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key)))

    if is_binary(value) and byte_size(value) > 0,
      do: {:ok, value},
      else: {:error, :invalid_machine_spec}
  end

  defp positive_integer(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key)))

    case value do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _ -> {:error, :invalid_machine_spec}
        end

      _ ->
        {:error, :invalid_machine_spec}
    end
  end

  defp optional_uuid(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key)))

    cond do
      value in [nil, ""] -> {:ok, nil}
      is_binary(value) and OverallsProtocol.uuid?(value) -> {:ok, value}
      true -> {:error, :invalid_machine_spec}
    end
  end
end
