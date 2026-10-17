defmodule Audi.DNS.Challenge do
  @moduledoc "Bounded DNS-01 proof sets, independent of application route readiness."

  @type t :: %{challenges: [binary()], expires_at: integer()}

  # @cc [owner:ghuntley,label:security;protocol] dns-challenge-scope
  # Challenge entries MUST contain at most four distinct canonical SHA-256
  # base64url digests at canonical VM or single-layer Inception challenge owners. They MUST carry
  # a monotonic expiry independent of snapshot renewal. Proofs MUST NOT publish
  # application addresses or authorize application access.
  @spec valid?(term(), term(), binary() | nil) :: boolean()
  def valid?(name, entry, zone \\ nil)

  def valid?(name, %{challenges: values, expires_at: expiry} = entry, zone)
      when is_binary(name) and is_list(values) and is_integer(expiry) and map_size(entry) == 2 do
    String.valid?(name) and valid_name?(name, zone) and proofs?(values)
  end

  def valid?(_, _, _), do: false

  @spec proofs?(term()) :: boolean()
  def proofs?(values) when is_list(values),
    do:
      length(values) in 1..4 and length(Enum.uniq(values)) == length(values) and
        Enum.all?(values, &digest?/1)

  def proofs?(_), do: false

  @spec live?(t()) :: boolean()
  def live?(entry), do: entry.expires_at > System.monotonic_time(:millisecond)

  defp valid_name?(name, zone) when byte_size(name) <= 253 do
    if is_binary(zone) and name == "_acme-challenge." <> zone do
      true
    else
      ordinary_name?(name)
    end
  end

  defp valid_name?(_, _), do: false

  defp ordinary_name?(name) do
    case String.split(name, ".") do
      ["_acme-challenge", "control", environment, "inception" | [_ | _] = zone] ->
        OverallsProtocol.IngressName.valid_label?(environment) and
          Enum.all?(zone, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))

      ["_acme-challenge", "apps", environment, "inception" | [_ | _] = zone] ->
        OverallsProtocol.IngressName.valid_label?(environment) and
          Enum.all?(zone, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))

      ["_acme-challenge", vm | [_ | _] = zone] ->
        OverallsProtocol.IngressName.valid_label?(vm) and
          Enum.all?(zone, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))

      _ ->
        false
    end
  end

  defp digest?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == value

      _ ->
        false
    end
  end

  defp digest?(_), do: false
end
