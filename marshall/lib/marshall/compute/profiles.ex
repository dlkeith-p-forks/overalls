defmodule Marshall.Compute.Profiles do
  @moduledoc "Inception's image binding, fixed service minima and placement prerequisite."
  @minimum %{vcpu: 16, memory_bytes: 34_359_738_368, disk_bytes: 68_719_476_736}

  @spec inception_image_id() :: String.t() | nil
  def inception_image_id do
    case Application.get_env(:marshall, :inception_image_id) do
      id when is_binary(id) -> if OverallsProtocol.ImageManifest.id?(id), do: id
      _ -> nil
    end
  end

  @spec default_shape(atom() | String.t(), map()) :: map()
  def default_shape(profile, image) when profile in [:inception, "inception"] do
    ordinary = Marshall.Compute.Image.default_shape(image)

    Map.merge(ordinary, @minimum, fn _key, image_minimum, profile_minimum ->
      max(image_minimum, profile_minimum)
    end)
  end

  def default_shape(_, image), do: Marshall.Compute.Image.default_shape(image)

  # @cc [owner:ghuntley,label:security;capacity] inception-admission-image-binding
  # Inception MUST use the explicitly configured image and meet its service
  # resource minima. Other profiles MUST NOT select that image. No profile or
  # image selection may substitute an allowlist for ordinary VM-create authority.
  @spec validate(map()) ::
          :ok
          | {:error,
             :inception_unavailable | :profile_image_mismatch | :image_requirements_not_met}
  def validate(%{profile: :inception} = request) do
    cond do
      is_nil(inception_image_id()) -> {:error, :inception_unavailable}
      request.image_id != inception_image_id() -> {:error, :profile_image_mismatch}
      not size_valid?(:inception, request) -> {:error, :image_requirements_not_met}
      true -> :ok
    end
  end

  def validate(request) do
    if request.image_id == inception_image_id(),
      do: {:error, :profile_image_mismatch},
      else: :ok
  end

  @spec size_valid?(atom(), map()) :: boolean()
  def size_valid?(:inception, sizes) do
    Enum.all?(@minimum, fn {key, minimum} ->
      value = Map.get(sizes, key, Map.get(sizes, Atom.to_string(key)))
      is_integer(value) and value >= minimum
    end)
  end

  def size_valid?(_, _), do: true

  # @cc [owner:ghuntley,label:capacity] inception-placement-requires-native-proof
  # Admission and subsequent execution MUST require fresh host inventory naming
  # this image as having passed the native nested Firecracker prerequisite.
  # CPU flags, ordinary execution_ready and image availability alone MUST NOT
  # establish eligibility. Lilly owns generation and validation of that evidence.
  @spec host_ready?(map(), map()) :: boolean()
  def host_ready?(%{profile: :inception, image_id: id}, inventory),
    do: Map.get(inventory, "inception_image_id") == id

  def host_ready?(_, _), do: true
end
