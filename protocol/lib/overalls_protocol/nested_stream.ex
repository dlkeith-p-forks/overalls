defmodule OverallsProtocol.NestedStream do
  @moduledoc "Closed parent namespace lease messages for fixed nested services."
  alias OverallsProtocol.{IngressConnect, IngressName, SSHKey, WebLogin}

  @services Map.new(
              [:control_https, :porsche_ssh, :audi_https, :audi_ssh],
              &{Atom.to_string(&1), &1}
            )

  # @cc [owner:ghuntley,label:security] nested-stream-wire-boundary
  # Requests MUST select only a canonical environment label and fixed service.
  # SSH requests require a canonical key attested by the authenticated gateway;
  # HTTPS requests MUST carry no user key. Unknown fields and arbitrary addresses
  # or ports MUST fail. Peer strings MUST NOT create atoms.
  @spec request(term(), term()) :: {:ok, atom(), map()} | {:error, :invalid_message}
  def request(
        "nested-open",
        %{"version" => 1, "label" => label, "nested_service" => kind, "public_key" => key} = value
      )
      when map_size(value) == 4 do
    with true <- IngressName.valid_label?(label),
         service when not is_nil(service) <- Map.get(@services, kind),
         true <- key?(service, key) do
      {:ok, :open_nested, %{label: label, nested_service: service, public_key: key}}
    else
      _ -> invalid()
    end
  end

  def request(route, %{"version" => 1, "stream_token" => token} = value)
      when route in ["nested-renew", "nested-close"] and map_size(value) == 2 do
    if ticket?(token),
      do:
        {:ok, if(route == "nested-renew", do: :renew_nested, else: :close_nested),
         %{stream_token: token}},
      else: invalid()
  end

  def request(_, _), do: invalid()

  # @cc [owner:ghuntley,label:security] nested-stream-response-binding
  # Grants MUST match requested host, namespace and service, contain a bounded
  # TTL and a purpose-bound ticket. Renewals MUST preserve every connector field
  # and the selected SSH host key. Valid syntax MUST NOT substitute another VM.
  @spec response(term(), term(), map(), map() | nil) :: {:ok, map()} | {:error, :invalid_message}
  def response(route, value, expected, previous \\ nil)

  def response(
        "nested-close",
        %{"version" => 1, "result" => %{"closed" => true} = result} = value,
        _,
        _
      )
      when map_size(value) == 2 and map_size(result) == 1, do: {:ok, %{closed: true}}

  def response(route, %{"version" => 1, "grant" => grant} = value, expected, previous)
      when route in ["nested-open", "nested-renew"] and map_size(value) == 2 and is_map(grant) do
    user = grant["user_id"]
    base = if(route == "nested-open", do: 4, else: 3)

    with true <- map_size(grant) == base + if(Map.has_key?(grant, "user_id"), do: 1, else: 0),
         true <- is_nil(user) or OverallsProtocol.uuid?(user),
         %{"binding" => wire, "ttl" => ttl, "host_key" => key} <- grant,
         true <- is_integer(ttl) and ttl in 1..30_000,
         {:ok, binding} <- IngressConnect.decode(JSON.encode!(%{version: 2, binding: wire})),
         true <- Enum.all?([:host_id, :label, :service], &(binding[&1] == expected[&1])),
         true <- key?(binding.service, key),
         true <-
           if(route == "nested-open",
             do: ticket?(grant["ticket"]),
             else: is_map(previous) and previous.binding == binding and previous.host_key == key
           ) do
      result = %{binding: binding, ttl: ttl, host_key: key, user_id: user}

      {:ok,
       if(route == "nested-open", do: Map.put(result, :ticket, grant["ticket"]), else: result)}
    else
      _ -> invalid()
    end
  end

  def response(_, _, _, _), do: invalid()

  @spec ticket?(term()) :: boolean()
  def ticket?("audi_nested_stream_" <> encoded), do: WebLogin.state?(encoded)
  def ticket?(_), do: false
  defp key?(kind, nil) when kind in [:control_https, :audi_https], do: true

  defp key?(kind, key) when kind in [:porsche_ssh, :audi_ssh] do
    case SSHKey.parse(key) do
      {:ok, parsed} -> parsed.public_key == key
      _ -> false
    end
  end

  defp key?(_, _), do: false
  defp invalid, do: {:error, :invalid_message}
end
