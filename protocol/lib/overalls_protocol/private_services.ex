defmodule OverallsProtocol.PrivateServices do
  @moduledoc "Closed identities for host-local private services; never request authority."
  @address "169.254.254.1"
  @hostname "llm.internal"
  @integration_zone "integration.internal"
  @certificate_names ["llm.internal", "reflection.internal", "*.integration.internal"]
  @fields ~w(host_id vm_id placement_id execution_epoch)
  @type binding :: %{
          host_id: binary(),
          vm_id: binary(),
          placement_id: binary(),
          execution_epoch: pos_integer()
        }

  @spec address() :: binary()
  def address, do: @address
  @spec hostname() :: binary()
  def hostname, do: @hostname
  @spec integration_zone() :: binary()
  def integration_zone, do: @integration_zone
  @spec lifetimes() :: %{root: 20, intermediate: 10, server: 10}
  def lifetimes, do: %{root: 20, intermediate: 10, server: 10}

  # @cc [owner:ghuntley,label:security] internal-service-closed-binding
  # Bindings MUST contain exactly the host, VM, placement and positive execution
  # epoch. Parsing MUST NOT grant authority or create atoms from peer values.
  @spec binding(term()) :: {:ok, binding()} | {:error, :invalid_binding}
  def binding(value) when is_map(value) and map_size(value) == 4 do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@fields),
         true <- Enum.all?(Enum.take(@fields, 3), &OverallsProtocol.uuid?(value[&1])),
         epoch = value["execution_epoch"],
         true <- is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807 do
      {:ok,
       %{
         host_id: value["host_id"],
         vm_id: value["vm_id"],
         placement_id: value["placement_id"],
         execution_epoch: epoch
       }}
    else
      _ -> {:error, :invalid_binding}
    end
  end

  def binding(_), do: {:error, :invalid_binding}

  @type roster_binding :: %{
          host_id: binary(),
          vm_id: binary(),
          placement_id: binary(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          operation_id: binary()
        }

  # @cc [owner:ghuntley,label:security;protocol] roster-bootstrap-exact-operation
  # Bootstrap identities MUST contain exactly the ordinary physical binding plus
  # a positive generation and operation UUID. Only the scoped SSH roster and host-certificate endpoints may
  # consume them; the ordinary binding decoder MUST continue rejecting them.
  @spec roster_binding(term()) :: {:ok, roster_binding()} | {:error, :invalid_binding}
  def roster_binding(%{"generation" => generation, "operation_id" => operation} = wire)
      when map_size(wire) == 6 do
    with {:ok, binding} <- __MODULE__.binding(Map.drop(wire, ~w(generation operation_id))),
         true <- is_integer(generation) and generation in 1..9_223_372_036_854_775_807,
         true <- OverallsProtocol.uuid?(operation) do
      {:ok, Map.merge(binding, %{generation: generation, operation_id: operation})}
    else
      _ -> {:error, :invalid_binding}
    end
  end

  def roster_binding(_), do: {:error, :invalid_binding}

  # @cc [owner:ghuntley,label:security] internal-certificate-fleet-wildcard
  # The whole fleet serves private TLS with one offline-issued certificate
  # covering the fixed Ziggy and reflection names and each single-label name in
  # the integration zone. Certificate names MUST NOT bind a host, placement or
  # caller-selected value; rotation is operator custody, not runtime issuance.
  @spec certificate_names() :: [binary()]
  def certificate_names, do: @certificate_names

  @typedoc "Why a private request asks Lilly for its source's execution."
  @type purpose :: :services | :ssh_roster | :ssh_host_certificate
  @purposes %{
    "services" => :services,
    "ssh_roster" => :ssh_roster,
    "ssh_host_certificate" => :ssh_host_certificate
  }

  # @cc [owner:ghuntley,label:protocol;security] private-binding-subscription-wire
  # Version 3 is the only private lookup: Audi sends one closed request with a
  # canonical IPv4 source address and a purpose from the fixed table; Lilly
  # answers one grant whose binding validates for that purpose and then keeps
  # the connection open, sending only the fixed revocation frame (or closing)
  # when the binding ends. Unknown fields, versions or purposes MUST refuse;
  # purpose strings MUST NOT become atoms outside the fixed table.
  @spec watch_request(String.t(), purpose()) :: map()
  def watch_request(address, purpose) do
    %{"version" => 3, "address" => address, "purpose" => purpose_name(purpose)}
  end

  @spec decode_watch_request(term()) :: {:ok, String.t(), purpose()} | {:error, :invalid_request}
  def decode_watch_request(
        %{"version" => 3, "address" => address, "purpose" => purpose} = request
      )
      when map_size(request) == 3 and is_binary(address) and is_binary(purpose) do
    with {:ok, atom} <- Map.fetch(@purposes, purpose),
         {:ok, {_, _, _, _} = ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         true <- to_string(:inet.ntoa(ip)) == address do
      {:ok, address, atom}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def decode_watch_request(_), do: {:error, :invalid_request}

  @spec grant(purpose(), map()) :: map()
  def grant(purpose, binding),
    do: %{"version" => 3, "purpose" => purpose_name(purpose), "binding" => binding}

  @spec decode_grant(term(), purpose()) :: {:ok, map()} | {:error, :invalid_grant}
  def decode_grant(%{"version" => 3, "purpose" => name, "binding" => wire} = grant, purpose)
      when map_size(grant) == 3 do
    valid =
      case purpose do
        :services -> __MODULE__.binding(wire)
        _roster -> __MODULE__.roster_binding(wire)
      end

    if name == purpose_name(purpose) and match?({:ok, _}, valid),
      do: {:ok, wire},
      else: {:error, :invalid_grant}
  end

  def decode_grant(_, _), do: {:error, :invalid_grant}

  @spec revocation() :: map()
  def revocation, do: %{"version" => 3, "revoked" => true}

  @spec revocation?(term()) :: boolean()
  def revocation?(frame), do: frame == revocation()

  defp purpose_name(:services), do: "services"
  defp purpose_name(:ssh_roster), do: "ssh_roster"
  defp purpose_name(:ssh_host_certificate), do: "ssh_host_certificate"
end
