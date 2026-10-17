defmodule OverallsProtocol.EditorLogin do
  @moduledoc "Purpose-separated browser editor login exchange; only Marshall may approve a user."
  alias OverallsProtocol.{EditorName, WebLogin}

  @prefixes %{
    ticket: "audi_editor_login_",
    code: "audi_editor_code_",
    cookie: "audi_editor_cookie_"
  }

  # @cc [owner:ghuntley,label:security;protocol] editor-login-closed-exchange
  # Login requests MUST bind the exact account origin and browser state without
  # accepting a caller's principal, permission, callback or guest destination.
  @spec request(term(), term()) :: {:ok, atom(), map()} | {:error, :invalid_request}
  def request(
        "editor-login-begin",
        %{"version" => 1, "label" => label, "state_digest" => digest} = value
      )
      when map_size(value) == 3 do
    if EditorName.valid_label?(label) and OverallsProtocol.EditorRelease.digest?(digest, 64),
      do: {:ok, :begin_editor_login, %{label: label, state_digest: digest}},
      else: {:error, :invalid_request}
  end

  def request(
        "editor-login-exchange",
        %{"version" => 1, "ticket" => ticket, "code" => code, "state" => state} = value
      )
      when map_size(value) == 4 do
    if token?(ticket, :ticket) and token?(code, :code) and state?(state),
      do: {:ok, :exchange_editor_login, %{ticket: ticket, code: code, state: state}},
      else: {:error, :invalid_request}
  end

  def request(_, _), do: {:error, :invalid_request}

  @spec response(term(), term(), String.t()) :: {:ok, map()} | {:error, :invalid_message}
  def response(route, %{"version" => 1, "login" => login} = value, hostname)
      when route in ["editor-login-begin", "editor-login-exchange"] and map_size(value) == 2 and
             is_map(login) and map_size(login) == 3 do
    {field, purpose} =
      if route == "editor-login-begin", do: {"ticket", :ticket}, else: {"cookie", :cookie}

    with %{"hostname" => ^hostname, "expires_at" => expiry} <- login,
         token = login[field],
         true <- token?(token, purpose),
         true <- is_binary(expiry) and byte_size(expiry) in 20..40,
         {:ok, expires_at, 0} <- DateTime.from_iso8601(expiry),
         do: {:ok, %{purpose => token, :hostname => hostname, :expires_at => expires_at}},
         else: (_ -> {:error, :invalid_message})
  end

  def response(_, _, _), do: {:error, :invalid_message}

  @spec state?(term()) :: boolean()
  def state?(value), do: WebLogin.state?(value)

  @spec token?(term(), :ticket | :code | :cookie) :: boolean()
  def token?(value, purpose) when is_binary(value) and byte_size(value) <= 80 do
    with prefix when is_binary(prefix) <- @prefixes[purpose],
         true <- String.starts_with?(value, prefix) and byte_size(value) == byte_size(prefix) + 43,
         do: state?(binary_part(value, byte_size(prefix), 43)),
         else: (_ -> false)
  end

  def token?(_, _), do: false
end
