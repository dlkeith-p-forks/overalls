defmodule MarshallWeb.MachineDefaults do
  @moduledoc """
  Account-backed browser machine-creation defaults shared by the create forms and
  repository launch.

  Values are the form's string parameters (`"vcpu"`, `"memory_mib"`, `"disk_gib"`,
  `"image_id"`, `"profile"`); transactional admission remains the authority.
  """

  alias Marshall.Accounts.User

  @typedoc "Catalog images as returned by `Marshall.Compute.catalog/2`."
  @type image :: %{
          required(:id) => String.t(),
          required(:minimum_memory_bytes) => pos_integer(),
          required(:minimum_disk_bytes) => pos_integer(),
          optional(atom()) => term()
        }

  @type preset :: :launch | :machine | :thread
  @type values :: %{optional(String.t()) => String.t() | nil}

  @type user_defaults :: %{
          optional(:launch_default_profile) => atom(),
          optional(:launch_default_image_id) => String.t() | nil,
          optional(:launch_default_vcpu) => pos_integer() | nil,
          optional(:launch_default_memory_bytes) => pos_integer() | nil,
          optional(:launch_default_disk_bytes) => pos_integer() | nil,
          optional(:machine_default_profile) => atom(),
          optional(:machine_default_image_id) => String.t() | nil,
          optional(:machine_default_vcpu) => pos_integer() | nil,
          optional(:machine_default_memory_bytes) => pos_integer() | nil,
          optional(:machine_default_disk_bytes) => pos_integer() | nil,
          optional(:thread_default_profile) => atom(),
          optional(:thread_default_image_id) => String.t() | nil,
          optional(:thread_default_vcpu) => pos_integer() | nil,
          optional(:thread_default_memory_bytes) => pos_integer() | nil,
          optional(:thread_default_disk_bytes) => pos_integer() | nil
        }

  @field_names %{
    launch: %{
      profile: :launch_default_profile,
      image_id: :launch_default_image_id,
      vcpu: :launch_default_vcpu,
      memory_bytes: :launch_default_memory_bytes,
      disk_bytes: :launch_default_disk_bytes
    },
    machine: %{
      profile: :machine_default_profile,
      image_id: :machine_default_image_id,
      vcpu: :machine_default_vcpu,
      memory_bytes: :machine_default_memory_bytes,
      disk_bytes: :machine_default_disk_bytes
    },
    thread: %{
      profile: :thread_default_profile,
      image_id: :thread_default_image_id,
      vcpu: :thread_default_vcpu,
      memory_bytes: :thread_default_memory_bytes,
      disk_bytes: :thread_default_disk_bytes
    }
  }

  @doc "Resolves one account preset into the machine form's string values."
  # @cc [owner:ghuntley,label:product;capacity] independent-account-presets
  # Each creation surface MUST resolve only its own preset. Missing preferences
  # default to OSS for launch and Standard for machines/threads. Unavailable or
  # incompatible saved images MUST fall back to a usable catalog image; invalid
  # saved sizes MUST fall back to whole-unit sizes meeting that image's minima.
  @spec for_user(User.t() | user_defaults(), preset(), [image()], keyword()) :: values()
  def for_user(user, preset, images, opts \\ []) when preset in [:launch, :machine, :thread] do
    fields = @field_names[preset]
    configured_profile = Map.get(user, fields.profile)

    profile =
      if configured_profile in [:standard, :oss],
        do: configured_profile,
        else: default_profile(preset)

    source_required? = Keyword.get(opts, :source_required?, false)
    selected_image = select_image(user, fields.image_id, profile, images, source_required?)
    image = selected_image || fallback_image(profile, images, source_required?)

    shape =
      configured_shape(user, fields)
      |> valid_shape_or_default(profile, image)

    %{
      "profile" => Atom.to_string(profile),
      "image_id" => image_id(image),
      "vcpu" => to_string(shape.vcpu),
      "memory_mib" => to_string(div(shape.memory_bytes, 1_048_576)),
      "disk_gib" => to_string(div(shape.disk_bytes, 1_073_741_824))
    }
  end

  @spec default_profile(preset()) :: :standard | :oss
  def default_profile(:launch), do: :oss
  def default_profile(_), do: :standard

  @spec source_capable?(String.t()) :: boolean()
  def source_capable?(image_id) when is_binary(image_id) do
    Marshall.Compute.Images.workspace_source_capable?(image_id)
  end

  def source_capable?(_), do: false

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

  @spec select_image(User.t() | user_defaults(), atom(), atom(), [image()], boolean()) ::
          image() | nil
  defp select_image(user, field, profile, images, source_required?) do
    image_id = Map.get(user, field)

    Enum.find(images, fn image ->
      image.id == image_id and
        image_usable?(image, profile, source_required?)
    end)
  end

  @spec fallback_image(atom(), [image()], boolean()) :: image() | nil
  defp fallback_image(profile, images, source_required?) do
    preferred = Application.get_env(:marshall, :default_image_id)

    Enum.find(images, &(&1.id == preferred and image_usable?(&1, profile, source_required?))) ||
      Enum.find(images, &image_usable?(&1, profile, source_required?))
  end

  @spec image_usable?(image(), atom(), boolean()) :: boolean()
  defp image_usable?(image, profile, source_required?) do
    image.id != Marshall.Compute.Profiles.inception_image_id() and
      (not source_required? or source_capable?(image.id)) and
      profile in [:standard, :oss]
  end

  @spec image_id(image() | nil) :: String.t()
  defp image_id(%{id: id}), do: id
  defp image_id(_), do: ""

  @spec configured_shape(User.t() | user_defaults(), map()) :: map()
  defp configured_shape(user, fields) do
    %{
      vcpu: Map.get(user, fields.vcpu),
      memory_bytes: Map.get(user, fields.memory_bytes),
      disk_bytes: Map.get(user, fields.disk_bytes)
    }
  end

  @spec valid_shape_or_default(map(), atom(), image() | nil) :: map()
  defp valid_shape_or_default(shape, profile, image) do
    default =
      Marshall.Compute.Profiles.default_shape(
        profile,
        image || %{minimum_memory_bytes: 536_870_912, minimum_disk_bytes: 2_147_483_648}
      )

    if valid_shape?(shape, image), do: shape, else: default
  end

  @spec valid_shape?(map(), image() | nil) :: boolean()
  defp valid_shape?(%{vcpu: vcpu, memory_bytes: memory, disk_bytes: disk}, image)
       when is_integer(vcpu) and is_integer(memory) and is_integer(disk) do
    OverallsProtocol.VMShape.valid?(vcpu, memory, disk) and
      rem(memory, 1_048_576) == 0 and rem(disk, 1_073_741_824) == 0 and
      (is_nil(image) or
         (memory >= image.minimum_memory_bytes and disk >= image.minimum_disk_bytes))
  end

  defp valid_shape?(_, _), do: false
end
