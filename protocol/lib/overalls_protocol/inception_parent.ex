defmodule OverallsProtocol.InceptionParent do
  @moduledoc "Public parent discovery metadata; never a credential or stream grant."

  # @cc [owner:ghuntley,label:security] inception-parent-discovery-scope
  # Parent metadata MUST contain only one canonical HTTPS origin and the exact
  # environment label/zone. IPv6, credentials, paths, queries, fragments and
  # shell/SSH expansion syntax MUST fail. Nil disables parent SSH discovery.
  @spec validate(term()) :: {:ok, map() | nil} | {:error, :invalid_inception_parent}
  def validate(nil), do: {:ok, nil}

  def validate(%{"origin" => origin, "label" => label, "zone" => zone} = value)
      when map_size(value) == 3 do
    with {:ok, _} <- OverallsProtocol.InceptionName.origins(label, zone),
         true <- is_binary(origin) and byte_size(origin) in 1..2048 and String.valid?(origin),
         {:ok, uri} <- URI.new(origin),
         true <- uri.scheme == "https" and hostname?(uri.host),
         true <-
           uri.path in [nil, ""] and is_nil(uri.userinfo) and
             is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         canonical = "https://#{uri.host}" <> if(uri.port == 443, do: "", else: ":#{uri.port}"),
         true <- origin == canonical do
      {:ok, value}
    else
      _ -> {:error, :invalid_inception_parent}
    end
  end

  def validate(_), do: {:error, :invalid_inception_parent}

  defp hostname?(value) when is_binary(value) and byte_size(value) in 1..253,
    do:
      Enum.all?(
        String.split(value, "."),
        &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
      )

  defp hostname?(_), do: false
end
