defmodule Marshall.Accounts.MachineDefaults do
  @moduledoc "Self-service machine creation defaults, scoped to the authenticated account."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Accounts.{Login, Security, User}
  alias Marshall.Compute.{Image, Ledger}

  @type preset :: :launch | :machine | :thread
  @type values :: %{
          profile: :standard | :oss,
          image_id: String.t(),
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer()
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

  # @cc [owner:ghuntley,label:security;capacity] machine-defaults-validated-before-write
  # A saved preset MUST name an enabled current image and a valid shape meeting
  # its image minima. Launch presets MUST use a workspace-capable image. Invalid
  # input MUST leave the account row unchanged.
  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, _, %{actor: %User{} = actor}) do
    preset = input.arguments[:preset]
    values = Map.take(input.arguments, [:profile, :image_id, :vcpu, :memory_bytes, :disk_bytes])

    with {:ok, image} <- enabled_image(values.image_id),
         :ok <- validate_profile(preset, values.profile),
         :ok <- validate_shape(values, image),
         :ok <- validate_launch_image(preset, image) do
      Ledger.transaction(fn ->
        user = Security.lock_user!(actor.id)
        token_id = Security.jti(actor)

        unless is_binary(token_id) and match?({:ok, _}, Login.token_present(token_id, user.id)),
          do: Ledger.rollback(:unauthorized)

        updated = Ledger.update!(user, :store_machine_defaults, update_attributes(preset, values))
        %{user_id: updated.id, preset: preset}
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  @spec enabled_image(String.t()) :: {:ok, map()} | {:error, :image_unavailable}
  defp enabled_image(image_id) do
    case Ledger.read!(Marshall.Compute.Image, id: image_id, enabled: true) do
      [image] -> {:ok, image}
      [] -> {:error, :image_unavailable}
    end
  end

  @spec validate_profile(preset(), atom()) :: :ok | {:error, atom()}
  defp validate_profile(preset, profile)
       when preset in [:launch, :machine, :thread] and profile in [:standard, :oss],
       do: :ok

  defp validate_profile(_, _), do: {:error, :invalid_profile}

  @spec validate_shape(values(), map()) :: :ok | {:error, atom()}
  defp validate_shape(values, image) do
    cond do
      image.id == Marshall.Compute.Profiles.inception_image_id() ->
        {:error, :profile_image_mismatch}

      not OverallsProtocol.VMShape.valid?(values.vcpu, values.memory_bytes, values.disk_bytes) ->
        {:error, :invalid_vm_size}

      rem(values.memory_bytes, 1_048_576) != 0 or rem(values.disk_bytes, 1_073_741_824) != 0 ->
        {:error, :invalid_vm_size}

      values.memory_bytes < image.minimum_memory_bytes or
          values.disk_bytes < image.minimum_disk_bytes ->
        {:error, :image_requirements_not_met}

      true ->
        :ok
    end
  end

  @spec validate_launch_image(preset(), map()) :: :ok | {:error, atom()}
  defp validate_launch_image(:launch, image) do
    if Image.workspace_source_capable?(image),
      do: :ok,
      else: {:error, :workspace_source_unavailable}
  end

  defp validate_launch_image(_, _), do: :ok

  @spec update_attributes(preset(), values()) :: map()
  defp update_attributes(preset, values) do
    fields = @field_names[preset]

    %{
      fields.profile => values.profile,
      fields.image_id => values.image_id,
      fields.vcpu => values.vcpu,
      fields.memory_bytes => values.memory_bytes,
      fields.disk_bytes => values.disk_bytes
    }
  end
end
