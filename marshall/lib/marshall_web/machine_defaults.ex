defmodule MarshallWeb.MachineDefaults do
  @moduledoc """
  Browser machine-creation defaults shared by the create form and repository launch.

  Values are the form's string parameters (`"vcpu"`, `"memory_mib"`, `"disk_gib"`,
  `"image_id"`, `"profile"`); transactional admission remains the authority.
  """

  @typedoc "Catalog images as returned by `Marshall.Compute.catalog/2`."
  @type image :: %{
          required(:id) => String.t(),
          optional(:minimum_memory_bytes) => pos_integer(),
          optional(:minimum_disk_bytes) => pos_integer(),
          optional(atom()) => term()
        }

  @type values :: %{optional(String.t()) => String.t() | nil}

  # @cc [owner:ghuntley,label:product;capacity] omitted-creation-size-defaults
  # Only omitted size fields may receive image-aware defaults. Explicit values,
  # including undersized or blank inputs, MUST remain unchanged for admission.
  # Byte minima MUST round up to the browser's whole MiB/GiB input units.
  @spec creation_defaults(values(), [image()]) :: values()
  def creation_defaults(values, images) do
    image = Enum.find(images, &(&1.id == values["image_id"]))

    defaults =
      Marshall.Compute.Profiles.default_shape(
        values["profile"],
        image || %{minimum_memory_bytes: 536_870_912, minimum_disk_bytes: 2_147_483_648}
      )

    Map.merge(
      %{
        "vcpu" => to_string(defaults.vcpu),
        "memory_mib" => to_string(div(defaults.memory_bytes, 1_048_576)),
        "disk_gib" => to_string(div(defaults.disk_bytes, 1_073_741_824))
      },
      values
    )
  end

  @doc "The configured default image for a profile, else the first ordinary catalog image."
  @spec default_image(String.t() | nil, [image()]) :: String.t()
  def default_image("inception", _images),
    do: Marshall.Compute.Profiles.inception_image_id() || ""

  def default_image(_, images) do
    Application.get_env(:marshall, :default_image_id) ||
      case Enum.reject(images, &(&1.id == Marshall.Compute.Profiles.inception_image_id())) do
        [image | _] -> image.id
        [] -> ""
      end
  end
end
