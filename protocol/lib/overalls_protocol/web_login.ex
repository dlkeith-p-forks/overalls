defmodule OverallsProtocol.WebLogin do
  @moduledoc "Closed browser exchange transport; user approval is not a gateway operation."
  @prefixes %{ticket: "audi_web_login_", code: "audi_web_code_", cookie: "audi_web_cookie_"}

  # @cc [owner:ghuntley,label:security;protocol] web-login-closed-transport
  # Gateway requests MUST contain only begin or redemption fields. User identity,
  # permission, callback URL and approval MUST NOT be caller-supplied authority.
  # Bearer purposes and state entropy MUST be canonical and non-interchangeable.
  @spec request(term(), term()) :: {:ok, atom(), map()} | {:error, :invalid_request}
  def request(
        "web-login-begin",
        %{"version" => 1, "label" => label, "app_port" => port, "state_digest" => digest} = value
      )
      when map_size(value) == 4 do
    if OverallsProtocol.IngressName.valid_label?(label) and is_integer(port) and
         (port == 0 or port in 3000..9999) and is_binary(digest) and byte_size(digest) == 64 and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
       do: {:ok, :begin_web_login, %{label: label, app_port: port, state_digest: digest}},
       else: {:error, :invalid_request}
  end

  def request(
        "web-login-exchange",
        %{"version" => 1, "ticket" => ticket, "code" => code, "state" => state} = value
      )
      when map_size(value) == 4 do
    if token?(ticket, :ticket) and token?(code, :code) and state?(state),
      do: {:ok, :exchange_web_login, %{ticket: ticket, code: code, state: state}},
      else: {:error, :invalid_request}
  end

  def request(_, _), do: {:error, :invalid_request}

  @spec response(term(), term(), binary()) :: {:ok, map()} | {:error, :invalid_message}
  def response(route, %{"version" => 1, "login" => login} = value, hostname)
      when map_size(value) == 2 and is_map(login) and map_size(login) == 3 do
    {field, purpose} =
      if route == "web-login-begin", do: {"ticket", :ticket}, else: {"cookie", :cookie}

    with true <- route in ["web-login-begin", "web-login-exchange"],
         %{"hostname" => ^hostname, "expires_at" => expires} <- login,
         token = Map.get(login, field),
         true <- token?(token, purpose),
         true <- is_binary(expires) and byte_size(expires) in 20..40,
         {:ok, expiry, 0} <- DateTime.from_iso8601(expires) do
      {:ok, %{purpose => token, :hostname => hostname, :expires_at => expiry}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def response(_, _, _), do: {:error, :invalid_message}

  @spec state?(term()) :: boolean()
  def state?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == value

      _ ->
        false
    end
  end

  def state?(_), do: false

  @spec token?(term(), :ticket | :code | :cookie) :: boolean()
  def token?(value, purpose) when is_binary(value) and byte_size(value) <= 80 do
    with prefix when is_binary(prefix) <- Map.get(@prefixes, purpose),
         true <- String.starts_with?(value, prefix) and byte_size(value) == byte_size(prefix) + 43,
         do: state?(binary_part(value, byte_size(prefix), 43)),
         else: (_ -> false)
  end

  def token?(_, _), do: false
end
