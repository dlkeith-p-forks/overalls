defmodule OverallsProtocol.IngressConnect do
  @moduledoc "Closed local SSH/web connector handshake; four-byte framing precedes an opaque stream."
  @maximum 2048
  @integer_max 9_223_372_036_854_775_807
  @fields [
    :vm_id,
    :host_id,
    :placement_id,
    :session_id,
    :execution_epoch,
    :generation,
    :label,
    :service,
    :port
  ]

  @nested [:control_https, :porsche_ssh, :audi_https, :audi_ssh]
  @services Map.new([:ssh, :web] ++ @nested, &{Atom.to_string(&1), &1})

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  # @cc [owner:ghuntley,label:security] ingress-connect-closed-binding
  # Requests MUST carry only a version and complete execution/session binding.
  # Version1 editor bindings MUST use the dedicated closed EditorConnect codec
  # with complete account, origin and release fields. Version 2 nested bindings additionally retain environment generation; their
  # service enum fixes the port. Ordinary SSH/web bindings remain version 1.
  # Unsupported services, ports, fields, versions and invalid identities MUST fail.
  # No guest address, path, credential or executable is supplied by the peer.
  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_connector_request}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum do
    case OverallsProtocol.EditorConnect.decode(bytes) do
      {:ok, binding} -> {:ok, binding}
      _ -> decode_ordinary(bytes)
    end
  end

  def decode(_), do: {:error, :invalid_connector_request}

  defp decode_ordinary(bytes) do
    with {:ok, %{"version" => version, "binding" => wire} = envelope} <- JSON.decode(bytes),
         true <- map_size(envelope) in [2, 3] and is_map(wire),
         fields when is_list(fields) <- fields(version),
         true <- map_size(wire) == length(fields),
         true <- Enum.all?(fields, &Map.has_key?(wire, Atom.to_string(&1))),
         binding = Map.new(fields, &{&1, Map.fetch!(wire, Atom.to_string(&1))}),
         service when not is_nil(service) <- Map.get(@services, binding.service),
         binding = %{binding | service: service},
         true <- valid?(binding),
         true <- version == version(binding),
         {:ok, binding} <- metadata(envelope, binding) do
      {:ok, binding}
    else
      _ -> {:error, :invalid_connector_request}
    end
  end

  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid_connector_request}
  def encode(%{service: :editor} = binding) do
    case OverallsProtocol.EditorConnect.encode(binding) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :invalid_connector_request}
    end
  end

  def encode(binding) do
    if valid?(binding) do
      {peer, base} = Map.pop(binding, :client_peer)
      envelope = %{version: version(base), binding: base}
      envelope = if peer, do: Map.put(envelope, :peer, peer), else: envelope
      {:ok, JSON.encode!(envelope)}
    else
      {:error, :invalid_connector_request}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{service: :editor} = binding), do: OverallsProtocol.EditorConnect.valid?(binding)

  def valid?(%{client_peer: peer, service: service} = binding)
      when map_size(binding) == 11 and service in [:control_https, :audi_https],
      do: OverallsProtocol.ProxyHeader.peer?(peer) and valid?(Map.delete(binding, :client_peer))

  def valid?(%{service: service, port: port} = binding)
      when map_size(binding) == 9 and
             ((service == :ssh and port == 22) or
                (service == :web and is_integer(port) and port >= 1 and port <= 65535 and
                   port != 4444)) do
    identity?(binding)
  end

  def valid?(%{service: service, port: port, environment_generation: revision} = binding)
      when map_size(binding) == 10 and service in @nested and
             is_integer(revision) and revision in 1..@integer_max do
    {_, expected_port} = OverallsProtocol.InceptionName.destination(service)
    port == expected_port and identity?(binding)
  end

  def valid?(_), do: false

  defp identity?(binding) do
    Enum.all?(
      [:vm_id, :host_id, :placement_id, :session_id],
      &OverallsProtocol.uuid?(binding[&1])
    ) and
      Enum.all?([:execution_epoch, :generation], fn key ->
        is_integer(binding[key]) and binding[key] in 1..@integer_max
      end) and OverallsProtocol.IngressName.valid_label?(binding[:label]) and
      String.ends_with?(binding.label, String.replace(String.downcase(binding.vm_id), "-", ""))
  end

  # @cc [owner:ghuntley,label:security] nested-connector-profile
  # Nested connector bindings MUST use version 2, retain environment generation,
  # and select only fixed services on an Inception-profile command. A valid nested
  # binding MUST NOT authorize access to an ordinary guest.
  # Ordinary services MUST also satisfy ProfilePolicy; Customer web is forbidden.
  @spec valid_for_profile?(term(), term()) :: boolean()
  def valid_for_profile?(binding, profile),
    do:
      valid?(binding) and
        if(binding.service in @nested,
          do: profile == :inception,
          else: OverallsProtocol.ProfilePolicy.allows?(profile, binding.service)
        )

  # @cc [owner:ghuntley,label:security] connector-client-metadata
  # Only nested HTTPS may carry a closed canonical IPv4 client endpoint from the
  # authenticated Audi peer. Metadata MUST NOT change the lease binding or
  # select a guest destination. Other services and unknown envelope fields fail.
  defp metadata(
         %{
           "version" => 2,
           "binding" => _,
           "peer" => %{"address" => address, "port" => port} = peer
         } = envelope,
         %{service: service} = binding
       )
       when map_size(envelope) == 3 and map_size(peer) == 2 and
              service in [:control_https, :audi_https] do
    result = Map.put(binding, :client_peer, %{address: address, port: port})
    if valid?(result), do: {:ok, result}, else: {:error, :invalid_connector_request}
  end

  defp metadata(envelope, binding) when map_size(envelope) == 2, do: {:ok, binding}
  defp metadata(_, _), do: {:error, :invalid_connector_request}

  defp fields(1), do: @fields
  defp fields(2), do: @fields ++ [:environment_generation]
  defp fields(_), do: nil
  defp version(%{service: service}) when service in @nested, do: 2
  defp version(_), do: 1

  @spec ready() :: binary()
  def ready, do: ~s({"version":1,"ready":true})

  @spec ready?(term()) :: boolean()
  def ready?(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum do
    case JSON.decode(bytes) do
      {:ok, %{"version" => 1, "ready" => true} = value} when map_size(value) == 2 -> true
      _ -> false
    end
  end

  def ready?(_), do: false
end
