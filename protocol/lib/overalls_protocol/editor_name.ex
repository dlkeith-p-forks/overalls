defmodule OverallsProtocol.EditorName do
  @moduledoc "Canonical single-label origins for one VM and immutable guest-account incarnation."
  @type identity :: %{vm_id: String.t(), guest_account_id: String.t()}

  # @cc [owner:ghuntley,label:security;protocol] editor-origin-complete-identities
  # Origins MUST retain both complete UUIDs in canonical lowercase RFC4648 base32.
  # Noncanonical padding bits and malformed editor prefixes MUST NOT fall back to
  # ordinary web routing. Browser storage is shared by origin, not guest UID.
  @spec label(String.t(), String.t()) :: String.t()
  def label(vm, account) do
    unless OverallsProtocol.uuid?(vm) and OverallsProtocol.uuid?(account),
      do: raise(ArgumentError, "invalid editor identity")

    "e-" <> encode(vm) <> "-" <> encode(account)
  end

  @spec parse(term()) :: {:ok, identity()} | :error
  def parse(<<"e-", vm::binary-size(26), "-", account::binary-size(26)>>) do
    with {:ok, vm_id} <- decode(vm),
         {:ok, guest_account_id} <- decode(account),
         do: {:ok, %{vm_id: vm_id, guest_account_id: guest_account_id}},
         else: (_ -> :error)
  end

  def parse(_), do: :error

  @spec valid_label?(term()) :: boolean()
  def valid_label?(value), do: match?({:ok, _}, parse(value))

  @spec webview_label?(term()) :: boolean()
  def webview_label?(value) when is_binary(value) and byte_size(value) == 52,
    do: Regex.match?(~r/\A[01][0-9a-v]{51}\z/, value)

  def webview_label?(_), do: false

  defp encode(uuid) do
    uuid
    |> String.replace("-", "")
    |> Base.decode16!(case: :mixed)
    |> Base.encode32(padding: false)
    |> String.downcase()
  end

  defp decode(value) do
    with true <- Regex.match?(~r/\A[a-z2-7]{26}\z/, value),
         {:ok, bytes} when byte_size(bytes) == 16 <-
           Base.decode32(String.upcase(value), padding: false),
         true <- String.downcase(Base.encode32(bytes, padding: false)) == value do
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> =
        Base.encode16(bytes, case: :lower)

      {:ok, Enum.join([a, b, c, d, e], "-")}
    else
      _ -> :error
    end
  end
end
