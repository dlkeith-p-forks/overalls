defmodule OverallsProtocol.IngressRelay do
  @moduledoc "One-hop fleet relay capabilities; never arbitrary network destinations."
  @prefix "audi_relay_"
  @maximum 4096
  @type route :: %{
          origin_host_id: String.t(),
          destination_host_id: String.t(),
          address: String.t(),
          port: :inet.port_number(),
          capability: String.t()
        }

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  # @cc [owner:ghuntley,label:security;protocol] ingress-relay-closed-fleet-route
  # Routes MUST bind distinct host UUIDs, a canonical fleet /32 and a purpose-bound
  # capability. Peer fields MUST NOT select a public address, path or second hop.
  @spec route(term()) :: {:ok, route()} | {:error, :invalid_message}
  def route(
        %{
          "origin_host_id" => source,
          "destination_host_id" => destination,
          "address" => address,
          "port" => port,
          "capability" => capability
        } = value
      )
      when map_size(value) == 5 do
    if OverallsProtocol.uuid?(source) and OverallsProtocol.uuid?(destination) and
         source != destination and fleet_address?(address) and
         is_integer(port) and port in 1..65_535 and capability?(capability) do
      {:ok,
       %{
         origin_host_id: source,
         destination_host_id: destination,
         address: address,
         port: port,
         capability: capability
       }}
    else
      {:error, :invalid_message}
    end
  end

  def route(_), do: {:error, :invalid_message}

  @spec fleet_address?(term()) :: boolean()
  def fleet_address?(value) when is_binary(value) and byte_size(value) in 9..13 do
    case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
      {:ok, {10, 90, 0, last} = address} when last in 1..254 ->
        List.to_string(:inet.ntoa(address)) == value

      _ ->
        false
    end
  end

  def fleet_address?(_), do: false

  @spec capability?(term()) :: boolean()
  def capability?(@prefix <> encoded) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == encoded

      _ ->
        false
    end
  end

  def capability?(_), do: false

  @spec encode(String.t(), String.t(), :ssh | :web | :editor) ::
          {:ok, binary()} | {:error, :invalid_message}
  def encode(capability, ticket, purpose) do
    value = %{
      "version" => 1,
      "capability" => capability,
      "ticket" => ticket,
      "purpose" => Atom.to_string(purpose)
    }

    case decode(value) do
      {:ok, _} -> {:ok, JSON.encode!(value)}
      error -> error
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] ingress-relay-preface-before-bytes
  # Only a bounded closed one-hop preface may precede the opaque stream. The
  # capability and inner ticket MUST retain separate purposes; unknown fields,
  # services and versions MUST refuse before guest contact.
  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_message}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum do
    case JSON.decode(bytes) do
      {:ok, value} -> decode(value)
      _ -> {:error, :invalid_message}
    end
  end

  def decode(
        %{
          "version" => 1,
          "capability" => capability,
          "ticket" => ticket,
          "purpose" => purpose
        } = value
      )
      when map_size(value) == 4 and purpose in ["ssh", "web", "editor"] do
    purpose =
      case purpose do
        "ssh" -> :ssh
        "web" -> :web
        "editor" -> :editor
      end

    if capability?(capability) and ticket?(ticket, purpose),
      do: {:ok, %{capability: capability, ticket: ticket, purpose: purpose}},
      else: {:error, :invalid_message}
  end

  def decode(_), do: {:error, :invalid_message}

  @spec ticket?(term(), :ssh | :web | :editor) :: boolean()
  defp ticket?(ticket, purpose) when is_binary(ticket) do
    prefix =
      case purpose do
        :ssh -> "audi_session_"
        :web -> "audi_web_stream_"
        :editor -> "audi_editor_stream_"
      end

    encoded = String.replace_prefix(ticket, prefix, "")

    byte_size(ticket) == byte_size(prefix) + 43 and String.starts_with?(ticket, prefix) and
      case Base.url_decode64(encoded, padding: false) do
        {:ok, <<_::256>> = bytes} -> Base.url_encode64(bytes, padding: false) == encoded
        _ -> false
      end
  end

  defp ticket?(_, _), do: false

  @spec ready() :: binary()
  def ready, do: "overalls-relay-ready-v1"
end
