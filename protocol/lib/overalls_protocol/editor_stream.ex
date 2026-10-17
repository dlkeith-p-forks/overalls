defmodule OverallsProtocol.EditorStream do
  @moduledoc "Private editor lease messages; identity, execution and package cannot drift on renewal."
  alias OverallsProtocol.{EditorConnect, EditorLogin, EditorName}

  @spec request(term(), term()) :: {:ok, atom(), map()} | {:error, :invalid_message}
  def request("editor-open", %{"version" => 1, "label" => label, "cookie" => cookie} = value)
      when map_size(value) == 3 do
    if EditorName.valid_label?(label) and (is_nil(cookie) or EditorLogin.token?(cookie, :cookie)),
      do: {:ok, :open_editor, %{label: label, cookie: cookie}},
      else: invalid()
  end

  def request(route, %{"version" => 1, "stream_token" => ticket} = value)
      when route in ["editor-renew", "editor-close"] and map_size(value) == 2 do
    if ticket?(ticket),
      do:
        {:ok, if(route == "editor-renew", do: :renew_editor, else: :close_editor),
         %{stream_token: ticket}},
      else: invalid()
  end

  def request(_, _), do: invalid()

  @spec ticket?(term()) :: boolean()
  def ticket?("audi_editor_stream_" <> encoded), do: EditorLogin.state?(encoded)
  def ticket?(_), do: false

  # @cc [owner:ghuntley,label:security;protocol] editor-renewal-exact-binding
  # Renewal MUST retain every principal/account/execution/release/origin field.
  # Replies MUST never select an arbitrary guest port or extend TTL beyond30s.
  @spec response(term(), term(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, :invalid_message}
  def response(route, value, host, label, previous \\ nil)

  def response(
        "editor-close",
        %{"version" => 1, "result" => %{"closed" => true} = result} = value,
        _,
        _,
        _
      )
      when map_size(value) == 2 and map_size(result) == 1, do: {:ok, %{closed: true}}

  def response(route, %{"version" => 1, "grant" => grant} = value, host, label, previous)
      when route in ["editor-open", "editor-renew"] and map_size(value) == 2 and is_map(grant) do
    with true <- map_size(grant) == if(route == "editor-open", do: 4, else: 3),
         %{"binding" => wire, "ttl" => ttl, "user_id" => user} <- grant,
         true <- is_integer(ttl) and ttl in 1..30_000 and OverallsProtocol.uuid?(user),
         {:ok, binding} <- EditorConnect.from_wire(wire),
         true <- binding.host_id == host and binding.label == label and binding.user_id == user,
         true <-
           if(route == "editor-open",
             do: ticket?(grant["ticket"]),
             else: is_map(previous) and previous.binding == binding and previous.user_id == user
           ) do
      result = %{binding: binding, user_id: user, ttl: ttl}

      {:ok,
       if(route == "editor-open", do: Map.put(result, :ticket, grant["ticket"]), else: result)}
    else
      _ -> invalid()
    end
  end

  def response(_, _, _, _, _), do: invalid()
  defp invalid, do: {:error, :invalid_message}
end
