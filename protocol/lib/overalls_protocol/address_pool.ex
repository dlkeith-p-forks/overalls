defmodule OverallsProtocol.AddressPool do
  @moduledoc "Profile /16 allocation identities; routing and isolation belong to the host driver."
  @type profile :: :customer | :standard | :oss | :inception
  # @cc [owner:ghuntley,label:network] profile-slot-stable-address
  # address/2 MUST map Customer, Standard, OSS and Inception slots injectively to 10.10.0.0/16,
  # 10.20.0.0/16, 10.30.0.0/16 and 10.40.0.0/16 respectively. Only integer slots 2 through 65534 are
  # allocatable; network, gateway and broadcast identities must be rejected.
  @spec address(profile(), integer()) :: {:ok, String.t()} | {:error, :invalid_address}
  def address(profile, slot)
      when profile in [:customer, :standard, :oss, :inception] and slot in 2..65534 do
    octet = %{customer: 10, standard: 20, oss: 30, inception: 40}[profile]
    {:ok, "10.#{octet}.#{div(slot, 256)}.#{rem(slot, 256)}"}
  end

  def address(_, _), do: {:error, :invalid_address}

  # @cc [owner:ghuntley,label:network] inception-paired-address-reservation
  # Inception's Audi address MUST use the same validated slot in 10.41/16.
  # It MUST NOT allocate an independent slot or overlap any control profile.
  # Ordinary guests MUST retain exactly their existing single address.
  @spec addresses(profile(), integer()) :: {:ok, [String.t()]} | {:error, :invalid_address}
  def addresses(profile, slot) do
    with {:ok, control} <- address(profile, slot) do
      if profile == :inception do
        {:ok, [control, "10.41.#{div(slot, 256)}.#{rem(slot, 256)}"]}
      else
        {:ok, [control]}
      end
    end
  end
end
