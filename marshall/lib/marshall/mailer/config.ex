defmodule Marshall.Mailer.Config do
  @moduledoc "Verified remote SMTP or explicitly selected host-local submission."
  alias Marshall.Accounts.EmailAddress

  @spec from_env(map()) :: {:ok, keyword(), {String.t(), String.t()}} | {:error, atom()}
  def from_env(env) do
    case Map.get(env, "MARSHALL_MAIL_TRANSPORT", "smtp") do
      "smtp" -> remote(env)
      "local_relay" -> local(env)
      _ -> {:error, :invalid_mail_configuration}
    end
  rescue
    _ -> {:error, :invalid_mail_configuration}
  end

  # @cc [owner:ghuntley,label:security] mail-local-explicit-loopback
  # Unauthenticated plaintext submission MUST require explicit local_relay mode
  # and the literal IPv4 loopback address; DNS names and other addresses fail.
  defp local(env) do
    with "127.0.0.1" <- env["MARSHALL_SMTP_HOST"],
         true <- EmailAddress.valid?(env["MARSHALL_MAIL_FROM"]),
         {port, ""} when port in 1..65_535 <-
           Integer.parse(Map.get(env, "MARSHALL_SMTP_PORT", "2525")) do
      {:ok,
       [
         adapter: Swoosh.Adapters.SMTP,
         relay: "127.0.0.1",
         port: port,
         auth: :never,
         ssl: false,
         tls: :never,
         retries: 0,
         no_mx_lookups: true,
         timeout: 3000
       ], {"Overalls", env["MARSHALL_MAIL_FROM"]}}
    else
      _ -> {:error, :invalid_mail_configuration}
    end
  end

  defp remote(env) do
    host = env["MARSHALL_SMTP_HOST"]
    mode = Map.get(env, "MARSHALL_SMTP_TLS", "implicit")
    from = env["MARSHALL_MAIL_FROM"]
    username = env["MARSHALL_SMTP_USERNAME"]
    password = env["MARSHALL_SMTP_PASSWORD"]
    default_port = if mode == "implicit", do: "465", else: "587"

    with true <- hostname?(host) and mode in ["implicit", "starttls"],
         true <- EmailAddress.valid?(from),
         true <- bounded?(username, 1024) and bounded?(password, 4096),
         {port, ""} when port in 1..65_535 <-
           Integer.parse(Map.get(env, "MARSHALL_SMTP_PORT", default_port)),
         {:ok, trust} <- trust(env) do
      tls =
        trust ++
          [
            verify: :verify_peer,
            versions: [:"tlsv1.2", :"tlsv1.3"],
            depth: 10,
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: host,
        port: port,
        username: username,
        password: password,
        auth: :always,
        ssl: mode == "implicit",
        tls: if(mode == "starttls", do: :always, else: :never),
        tls_options: tls,
        sockopts: if(mode == "implicit", do: tls, else: []),
        retries: 0,
        no_mx_lookups: true,
        timeout: 3000
      ]

      {:ok, config, {"Overalls", from}}
    else
      _ -> {:error, :invalid_mail_configuration}
    end
  rescue
    _ -> {:error, :invalid_mail_configuration}
  end

  # @cc [owner:ghuntley,label:security] mail-smtp-system-trust
  # Without MARSHALL_SMTP_CA_CERTFILE, remote SMTP TLS MUST trust the operating
  # system store, which honours the host's distrusted roots; a bundled Hex CA
  # list MUST NOT be the default. A configured CA file MUST be absolute and exist.
  defp trust(env) do
    case Map.fetch(env, "MARSHALL_SMTP_CA_CERTFILE") do
      {:ok, ca} when is_binary(ca) ->
        if Path.type(ca) == :absolute and File.regular?(ca),
          do: {:ok, [cacertfile: String.to_charlist(ca)]},
          else: :error

      {:ok, _} ->
        :error

      :error ->
        {:ok, [cacerts: :public_key.cacerts_get()]}
    end
  end

  defp hostname?(host),
    do: bounded?(host, 253) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/, host)

  defp bounded?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and
        not String.contains?(value, ["\r", "\n", "\0"])
end
