defmodule OverallsProtocol.SSHTrust do
  @moduledoc "One deployment's public SSH trust policy and certificate response schema."
  alias OverallsProtocol.SSHHostCertificate, as: Certificate

  @type t :: %{
          version: 1,
          ca: binary(),
          management_host: binary(),
          zone: binary(),
          retirement: pos_integer()
        }
  @lifetime 10 * 365 * 86_400
  @renewal 30 * 86_400
  @spec lifetime() :: pos_integer()
  def lifetime, do: @lifetime
  @spec renewal_window() :: pos_integer()
  def renewal_window, do: @renewal

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_trust}
  def parse(
        %{
          "version" => 1,
          "ca" => ca,
          "management_host" => host,
          "zone" => zone,
          "retirement" => retirement
        } = value
      )
      when map_size(value) == 5 and is_integer(retirement) and retirement > 0 do
    with {:ok, _} <- Certificate.ed25519(ca),
         true <- Certificate.hostname?(host) and byte_size(host) <= 180,
         true <- Certificate.hostname?(zone) and byte_size(zone) <= 189,
         {:ok, %{public_key: ^ca}} <- OverallsProtocol.SSHKey.parse(ca) do
      {:ok, %{version: 1, ca: ca, management_host: host, zone: zone, retirement: retirement}}
    else
      _ -> {:error, :invalid_trust}
    end
  end

  def parse(_), do: {:error, :invalid_trust}

  @spec response(term(), binary(), binary(), non_neg_integer()) ::
          {:ok, Certificate.t(), binary()} | {:error, :invalid_certificate}
  def response(
        %{"version" => 1, "certificate" => line, "principal" => principal, "ca" => ca} = value,
        ca,
        key,
        now
      )
      when map_size(value) == 4 do
    with {:ok, cert} <- Certificate.verify(line, ca, key, principal, now),
         do: {:ok, cert, line},
         else: (_ -> {:error, :invalid_certificate})
  end

  def response(_, _, _, _), do: {:error, :invalid_certificate}
end
