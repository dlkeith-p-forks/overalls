defmodule Lilly.Network.AndroidDisplay do
  @moduledoc "Validated Android display target derived from a guest identity."
  alias Lilly.Network.{Guest, Policy}
  @display_port 5900
  @type target :: %{
          address: String.t(),
          port: 5900,
          mark: pos_integer(),
          generation: pos_integer()
        }

  # @cc [owner:ghuntley,label:security;isolation] android-display-target-derived
  # The display target MUST be derived from the validated guest TAP identity,
  # use only the fixed guest RFB port, require an Android capability assertion,
  # and match the current emulator generation before any host socket is opened.
  @spec target(Guest.t(), map(), pos_integer()) ::
          {:ok, target()} | {:error, :display_unavailable}
  def target(%Guest{} = guest, %{android_display: true, generation: generation}, generation)
      when is_integer(generation) and generation > 0 do
    with {:ok, ^guest} <- Guest.new(guest.vm_id, guest.profile, guest.slot),
         true <- is_binary(guest.address) do
      {:ok,
       %{
         address: guest.address,
         port: @display_port,
         mark: Policy.android_display_mark(),
         generation: generation
       }}
    else
      _ -> {:error, :display_unavailable}
    end
  end

  def target(_, _, _), do: {:error, :display_unavailable}
end
