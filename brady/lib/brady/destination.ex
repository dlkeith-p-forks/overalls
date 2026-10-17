defmodule Brady.Destination do
  @moduledoc "Original-destination admission shared by intercepted requests and upstream sockets."
  import Bitwise
  @blocked ~w(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4)
  @type ipv4 :: {byte(), byte(), byte(), byte()}
  @type network :: {non_neg_integer(), non_neg_integer()}

  @spec policy([String.t()]) :: {:ok, [network()]} | {:error, :invalid_policy}
  def policy(protected) when is_list(protected) and length(protected) <= 256 do
    Enum.reduce_while(@blocked ++ protected, {:ok, []}, fn cidr, {:ok, acc} ->
      case cidr(cidr) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, {:error, :invalid_policy}}
      end
    end)
  end

  def policy(_), do: {:error, :invalid_policy}

  # @cc [owner:ghuntley,label:security] brady-upstream-public-destination
  # Only canonical IPv4 original destinations outside every private/special and
  # operator-protected range may be opened. IPv6 or invalid ports MUST fail.
  @spec allowed?(term(), term(), [network()]) :: boolean()
  def allowed?({a, b, c, d} = ip, port, policy)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
             is_integer(port) and port in 1..65535 do
    value = number(ip)
    not Enum.any?(policy, fn {network, mask} -> band(value, mask) == network end)
  end

  def allowed?(_, _, _), do: false

  @spec hostname(term()) :: {:ok, String.t()} | {:error, :invalid_authority}
  def hostname(value) when is_binary(value) and byte_size(value) in 1..253 do
    value = String.downcase(value)
    labels = String.split(value, ".")

    if Enum.all?(
         labels,
         &(byte_size(&1) in 1..63 and
             Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, &1))
       ), do: {:ok, value}, else: {:error, :invalid_authority}
  end

  def hostname(_), do: {:error, :invalid_authority}

  @spec authority(term(), pos_integer()) ::
          {:ok, String.t(), pos_integer()} | {:error, :invalid_authority}
  def authority(value, default_port) when is_binary(value) and byte_size(value) <= 260 do
    with [host | rest] <- String.split(value, ":"),
         {:ok, host} <- hostname(host),
         {:ok, port} <- port(rest, default_port) do
      {:ok, host, port}
    else
      _ -> {:error, :invalid_authority}
    end
  end

  def authority(_, _), do: {:error, :invalid_authority}

  # @cc [owner:ghuntley,label:security] brady-http-authority-original-ip
  # HTTP authority MUST resolve to the admitted original destination. Callers
  # MUST connect to that original IP, never a subsequently resolved address.
  # Resolver errors, mismatched ports and unexpected addresses MUST fail closed.
  @spec matches?(String.t(), pos_integer(), {ipv4(), pos_integer()}, (String.t() -> term())) ::
          boolean()
  def matches?(host, port, {ip, port}, resolver) do
    case hostname(host) do
      {:ok, canonical} ->
        case :inet.parse_ipv4strict_address(String.to_charlist(canonical)) do
          {:ok, address} ->
            address == ip

          _ ->
            case resolver.(canonical) do
              {:ok, addresses} when is_list(addresses) -> ip in addresses
              _ -> false
            end
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def matches?(_, _, _, _), do: false

  # @cc [owner:ghuntley,label:security] brady-https-origin-by-upstream-identity
  # Plain HTTP authority MUST resolve to the admitted original destination.
  # Intercepted HTTPS MUST carry a valid hostname on the original port but MUST
  # NOT depend on Brady's DNS view agreeing with the guest's: rotating and
  # geo-dependent answers (e.g. GitHub) differ between resolvers. The origin is
  # instead authenticated by upstream TLS verification of that hostname at the
  # pinned original IP before any response is served or stored (ADR-0069).
  @spec acceptable?(
          :http | :https,
          String.t(),
          pos_integer(),
          {ipv4(), pos_integer()},
          (String.t() ->
             term())
        ) ::
          boolean()
  def acceptable?(:http, host, port, destination, resolver),
    do: matches?(host, port, destination, resolver)

  def acceptable?(:https, host, port, {_ip, port}, _resolver) when is_binary(host),
    do: match?({:ok, ^host}, hostname(host))

  def acceptable?(_, _, _, _, _), do: false

  defp port([], default) when default in 1..65535, do: {:ok, default}

  defp port([value], _) do
    with true <- Regex.match?(~r/\A[0-9]{1,5}\z/, value),
         {number, ""} <- Integer.parse(value),
         true <- number in 1..65535,
         do: {:ok, number},
         else: (_ -> :error)
  end

  defp port(_, _), do: :error

  defp cidr(value) when is_binary(value) and byte_size(value) <= 18 do
    with [ip, prefix] <- String.split(value, "/"),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(ip)),
         {prefix, ""} <- Integer.parse(prefix),
         true <- prefix in 0..32,
         mask = bxor(0xFFFFFFFF, (1 <<< (32 - prefix)) - 1),
         network = number(address),
         true <- band(network, mask) == network do
      {:ok, {network, mask}}
    else
      _ -> :error
    end
  end

  defp cidr(_), do: :error
  defp number({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end
