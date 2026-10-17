defmodule Lilly.Network.Config do
  @moduledoc "Operator-owned host networking identity; independent from guest addresses."
  import Bitwise
  @enforce_keys [:host_id, :namespace, :uplink, :tag, :egress, :protected, :state_dir]
  defstruct [
    :host_id,
    :namespace,
    :uplink,
    :tag,
    :egress,
    :protected,
    :state_dir,
    ingress: false,
    private_services: false,
    brady: nil
  ]

  @type t :: %__MODULE__{
          host_id: String.t(),
          namespace: String.t(),
          uplink: String.t(),
          tag: String.t(),
          egress: String.t(),
          protected: [String.t()],
          state_dir: Path.t(),
          ingress: boolean(),
          private_services: boolean(),
          brady: map() | nil
        }

  # @cc [owner:ghuntley,label:security] operator-network-text-validated
  # new/4,5,6,7 MUST reject interface names that can alter nftables syntax and protected ranges that are
  # not canonical IPv4 network CIDRs; successful output must use deterministic host-scoped names
  # and a canonical absolute state path.
  @spec new(String.t(), String.t(), [String.t()], Path.t()) ::
          {:ok, t()} | {:error, :invalid_network_configuration}
  @spec new(String.t(), String.t(), [String.t()], Path.t(), boolean()) ::
          {:ok, t()} | {:error, :invalid_network_configuration}
  @spec new(String.t(), String.t(), [String.t()], Path.t(), boolean(), boolean(), map() | nil) ::
          {:ok, t()} | {:error, :invalid_network_configuration}
  def new(
        host,
        egress,
        protected,
        state_dir,
        ingress \\ false,
        private_services \\ false,
        brady \\ nil
      ) do
    with true <- OverallsProtocol.uuid?(host),
         true <- is_boolean(ingress) and is_boolean(private_services),
         true <- brady?(brady),
         true <-
           is_binary(egress) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}\z/, egress),
         true <-
           is_list(protected) and length(protected) <= 256 and Enum.all?(protected, &cidr?/1),
         true <-
           is_binary(state_dir) and Path.type(state_dir) == :absolute and
             Path.expand(state_dir) == state_dir do
      tag = :crypto.hash(:sha256, host) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      {:ok,
       %__MODULE__{
         host_id: host,
         namespace: "lilly-" <> tag,
         uplink: "lu" <> tag,
         tag: "lilly_" <> tag,
         egress: egress,
         protected: Enum.sort(Enum.uniq(protected)),
         state_dir: state_dir,
         ingress: ingress,
         private_services: private_services,
         brady: brady
       }}
    else
      _ -> {:error, :invalid_network_configuration}
    end
  end

  # @cc [owner:ghuntley,label:security] brady-policy-closed-operator-input
  # Proxy rule interpolation MUST accept only the closed UID/port/resolver
  # schema. Listener ports are fixed; guest-selected strings MUST NOT reach nft.
  defp brady?(nil), do: true

  defp brady?(%{"uid" => uid, "http_ports" => http, "https_ports" => https, "dns" => dns} = value)
       when map_size(value) == 4 do
    is_integer(uid) and uid in 1..999_999 and ports?(http) and ports?(https) and
      Enum.all?(http, &(&1 not in https)) and is_list(dns) and length(dns) in 1..8 and
      Enum.all?(dns, fn ip -> is_binary(ip) and cidr?(ip <> "/32") end)
  end

  defp brady?(_), do: false

  defp ports?(ports),
    do:
      is_list(ports) and length(ports) in 1..32 and
        Enum.all?(ports, &(is_integer(&1) and &1 in 1..65535)) and Enum.uniq(ports) == ports

  @spec cidr?(term()) :: boolean()
  def cidr?(value) when is_binary(value) do
    with [address, prefix] <- String.split(value, "/"),
         {prefix, ""} <- Integer.parse(prefix),
         true <- prefix in 0..32,
         {:ok, {a, b, c, d}} <- :inet.parse_ipv4_address(String.to_charlist(address)),
         true <- address == "#{a}.#{b}.#{c}.#{d}",
         number = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d,
         true <- band(number, bsl(1, 32 - prefix) - 1) == 0 do
      true
    else
      _ -> false
    end
  end

  def cidr?(_), do: false
end
