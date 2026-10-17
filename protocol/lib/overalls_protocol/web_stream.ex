defmodule OverallsProtocol.WebStream do
  @moduledoc "Closed web lease control messages; no guest destination supplied by callers."
  alias OverallsProtocol.{IngressName, WebLogin}
  @maximum 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:security] web-stream-wire-authority
  # Requests MUST name only a canonical VM label and allowed app selector, never
  # a guest address. Replies MUST carry bounded TTL, exact host/label identity and
  # a purpose-bound ticket. Unknown fields and peer-created atoms are forbidden.
  @spec request(term(), term()) :: {:ok, atom(), map()} | {:error, :invalid_message}
  def request(
        "web-open",
        %{"version" => 1, "label" => label, "app_port" => port, "cookie" => cookie} = value
      )
      when map_size(value) == 4 do
    if IngressName.valid_label?(label) and
         (is_integer(port) and (port == 0 or port in 3000..9999)) and
         (is_nil(cookie) or WebLogin.token?(cookie, :cookie)),
       do: {:ok, :open_web, %{label: label, app_port: port, cookie: cookie}},
       else: invalid()
  end

  def request(route, %{"version" => 1, "stream_token" => ticket} = value)
      when route in ["web-renew", "web-close"] and map_size(value) == 2 do
    if ticket?(ticket),
      do:
        {:ok, if(route == "web-renew", do: :renew_web, else: :close_web), %{stream_token: ticket}},
      else: invalid()
  end

  def request(_, _), do: invalid()

  @spec ticket?(term()) :: boolean()
  def ticket?("audi_web_stream_" <> encoded), do: WebLogin.state?(encoded)
  def ticket?(_), do: false

  @spec response(term(), term(), binary(), binary(), map() | nil) ::
          {:ok, map()} | {:error, :invalid_message}
  def response(route, value, host, label, previous \\ nil)

  def response(
        "web-close",
        %{"version" => 1, "result" => %{"closed" => true} = result} = value,
        _,
        _,
        _
      )
      when map_size(value) == 2 and map_size(result) == 1, do: {:ok, %{closed: true}}

  def response(route, %{"version" => 1, "grant" => grant} = value, host, label, previous)
      when route in ["web-open", "web-renew"] and map_size(value) == 2 and is_map(grant) do
    with true <- map_size(grant) == if(route == "web-open", do: 4, else: 3),
         %{"binding" => binding, "ttl" => ttl, "user_id" => user} <- grant,
         true <-
           is_integer(ttl) and ttl in 1..30_000 and (is_nil(user) or OverallsProtocol.uuid?(user)),
         {:ok, normalized} <- binding(binding, host, label),
         true <-
           if(route == "web-open",
             do: ticket?(grant["ticket"]),
             else:
               is_map(previous) and previous.binding == normalized and previous.user_id == user
           ) do
      result = %{binding: normalized, user_id: user, ttl: ttl}
      {:ok, if(route == "web-open", do: Map.put(result, :ticket, grant["ticket"]), else: result)}
    else
      _ -> invalid()
    end
  end

  def response(_, _, _, _, _), do: invalid()

  defp binding(
         %{
           "vm_id" => vm,
           "host_id" => host,
           "placement_id" => placement,
           "session_id" => session,
           "execution_epoch" => epoch,
           "generation" => generation,
           "label" => label,
           "service" => "web",
           "port" => port
         } = value,
         host,
         label
       )
       when map_size(value) == 9 do
    if Enum.all?([vm, host, placement, session], &OverallsProtocol.uuid?/1) and
         IngressName.valid_label?(label) and
         String.ends_with?(label, vm |> String.downcase() |> String.replace("-", "")) and
         is_integer(epoch) and epoch in 1..@maximum and is_integer(generation) and
         generation in 1..@maximum and
         is_integer(port) and port in 1..65535 do
      {:ok,
       %{
         vm_id: vm,
         host_id: host,
         placement_id: placement,
         session_id: session,
         execution_epoch: epoch,
         generation: generation,
         label: label,
         service: :web,
         port: port
       }}
    else
      invalid()
    end
  end

  defp binding(_, _, _), do: invalid()
  defp invalid, do: {:error, :invalid_message}
end
