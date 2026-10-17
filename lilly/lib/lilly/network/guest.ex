defmodule Lilly.Network.Guest do
  @moduledoc "Validated per-VM TAP and anti-spoofing identity."
  @enforce_keys [
    :vm_id,
    :profile,
    :slot,
    :address,
    :addresses,
    :gateway,
    :mac,
    :tap,
    :guard,
    :uid
  ]
  defstruct [:vm_id, :profile, :slot, :address, :addresses, :gateway, :mac, :tap, :guard, :uid]

  @type t :: %__MODULE__{
          vm_id: String.t(),
          profile: OverallsProtocol.AddressPool.profile(),
          slot: pos_integer(),
          address: String.t(),
          addresses: [String.t()],
          gateway: String.t(),
          mac: String.t(),
          tap: String.t(),
          guard: String.t(),
          uid: pos_integer()
        }

  # @cc [owner:ghuntley,label:security] guest-address-mac-uid-consistency
  # new/3 MUST derive address, MAC and reserved UID from the same validated profile/slot pair,
  # with distinct identities across profiles. An invalid VM UUID or reserved address slot must
  # fail before any host effect.
  @spec new(String.t(), OverallsProtocol.AddressPool.profile(), integer()) ::
          {:ok, t()} | {:error, :invalid_guest_network}
  def new(vm, profile, slot) do
    with true <- OverallsProtocol.uuid?(vm),
         {:ok, [address | _] = addresses} <- OverallsProtocol.AddressPool.addresses(profile, slot) do
      octet = %{customer: 10, standard: 20, oss: 30, inception: 40}[profile]

      mac =
        Enum.map_join([2, 252, 10, octet, div(slot, 256), rem(slot, 256)], ":", fn n ->
          n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
        end)

      tag = :crypto.hash(:sha256, vm) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      {:ok,
       %__MODULE__{
         vm_id: vm,
         profile: profile,
         slot: slot,
         address: address,
         addresses: addresses,
         gateway: "10.#{octet}.0.1",
         mac: mac,
         tap: "lv" <> tag,
         guard: "guard_" <> String.replace(vm, "-", ""),
         uid: 1_000_000 + (div(octet, 10) - 1) * 65_536 + slot
       }}
    else
      _ -> {:error, :invalid_guest_network}
    end
  end
end
