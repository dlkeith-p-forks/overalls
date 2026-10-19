defmodule Susan.Epmd do
  @moduledoc """
  Port mapper for the OCI image, which has no `/bin/sh` and therefore cannot
  let `erl` spawn `epmd`. Selected with
  `-start_epmd false -epmd_module Elixir.Susan.Epmd`.

  The service node `susan` listens on the fixed loopback distribution port
  `SUSAN_DIST_PORT` (default 4370); every other node (the `bin/susan rpc`
  client) listens on an ephemeral port. Every lookup answers the service
  port, because the only peer an operator node ever contacts is the service.
  Distribution stays bound to loopback through `inet_dist_use_interface`.
  """

  @default_port 4370
  @dist_version 6

  @spec start_link() :: :ignore
  def start_link, do: :ignore

  @spec register_node(atom() | charlist(), :inet.port_number()) :: {:ok, pos_integer()}
  def register_node(name, port), do: register_node(name, port, :inet_tcp)

  @spec register_node(atom() | charlist(), :inet.port_number(), atom()) :: {:ok, pos_integer()}
  def register_node(_name, _port, _driver), do: {:ok, :rand.uniform(0xFFFF_FFF0) + 3}

  @spec listen_port_please(atom() | charlist() | String.t(), charlist()) ::
          {:ok, :inet.port_number()}
  def listen_port_please(name, _host),
    do: {:ok, if(service?(name), do: service_port(), else: 0)}

  @spec port_please(charlist(), :inet.ip_address() | charlist()) ::
          {:port, :inet.port_number(), pos_integer()}
  def port_please(name, host), do: port_please(name, host, :infinity)

  @spec port_please(charlist(), :inet.ip_address() | charlist(), timeout()) ::
          {:port, :inet.port_number(), pos_integer()}
  def port_please(_name, _host, _timeout), do: {:port, service_port(), @dist_version}

  @spec address_please(charlist(), charlist(), :inet.address_family()) ::
          {:ok, :inet.ip_address()} | {:error, term()}
  def address_please(_name, host, family), do: :inet.getaddr(host, family)

  @spec names(term()) :: {:error, :address}
  def names(_host), do: {:error, :address}

  defp service?(name) when is_atom(name), do: name == :susan
  defp service?(name) when is_list(name), do: List.to_string(name) == "susan"
  defp service?(name) when is_binary(name), do: name == "susan"

  defp service_port do
    case Integer.parse(System.get_env("SUSAN_DIST_PORT", "")) do
      {port, ""} when port in 1024..65_535 -> port
      _ -> @default_port
    end
  end
end
