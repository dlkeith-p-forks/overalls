defmodule Marshall.Operations.RuntimeConfig do
  @moduledoc "Validated production listeners and a fleet-wide PostgreSQL connection budget."
  @derive {Inspect, except: [:repo]}
  @enforce_keys [:repo, :endpoint, :fleet_listeners, :replicas, :connection_budget, :instance_id]
  defstruct [:repo, :endpoint, :fleet_listeners, :replicas, :connection_budget, :instance_id]

  @type t :: %__MODULE__{
          repo: keyword(),
          endpoint: keyword(),
          fleet_listeners: [keyword()],
          replicas: pos_integer(),
          connection_budget: pos_integer(),
          instance_id: String.t()
        }
  # @cc [owner:ghuntley,label:deployment] configured-default-image-identity
  # A configured default image MUST be a canonical SHA-256 content identity.
  # Missing or empty configuration disables the default; invalid input MUST fail
  # without reflecting its contents. Selection never bypasses Ash admission.
  @spec default_image(map()) :: {:ok, String.t() | nil} | {:error, :invalid_default_image}
  def default_image(env) do
    case Map.get(env, "MARSHALL_DEFAULT_IMAGE_ID") do
      value when value in [nil, ""] ->
        {:ok, nil}

      value ->
        if OverallsProtocol.ImageManifest.id?(value),
          do: {:ok, value},
          else: {:error, :invalid_default_image}
    end
  end

  @spec inception_image(map()) :: {:ok, String.t() | nil} | {:error, :invalid_inception_image}
  def inception_image(env) do
    case default_image(%{
           "MARSHALL_DEFAULT_IMAGE_ID" => Map.get(env, "MARSHALL_INCEPTION_IMAGE_ID")
         }) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_inception_image}
    end
  end

  # @cc [owner:ghuntley,label:security] inception-public-runtime-input
  # An operator-selected public settings file MUST be regular, bounded to 64 KiB
  # and validated with the shared closed schema. Absence disables public setup;
  # malformed or unreadable input MUST fail with a fixed error, without contents.
  @spec inception_public(map()) :: {:ok, map() | nil} | {:error, :invalid_inception_public}
  def inception_public(env) do
    case Map.get(env, "MARSHALL_INCEPTION_PUBLIC_FILE") do
      nil -> {:ok, nil}
      path when is_binary(path) -> read_inception_public(path)
      _ -> {:error, :invalid_inception_public}
    end
  end

  defp read_inception_public(path) do
    with {:ok, %{type: :regular, size: size}} when size in 1..65_536 <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with bytes when is_binary(bytes) and byte_size(bytes) <= 65_536 <-
               IO.binread(file, 65_537),
             {:ok, value} when is_map(value) <- JSON.decode(bytes),
             {:ok, settings} <- OverallsProtocol.InceptionPublic.validate(value) do
          {:ok, settings}
        else
          _ -> {:error, :invalid_inception_public}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :invalid_inception_public}
    end
  rescue
    _ -> {:error, :invalid_inception_public}
  end

  @operator_headroom 10

  # @cc [owner:ghuntley,label:capacity] runtime-fleet-connection-budget
  # Production configuration MUST require 1..100 planned replicas and an instance
  # ID, and reject budgets below replicas * (pool_size + one notifier) + ten
  # operator connections. Returned Repo configuration MUST target a writable
  # primary and use one pool per instance.

  # @cc [owner:ghuntley,label:security] runtime-sanitized-configuration-error
  # Invalid production environment input MUST return the fixed
  # invalid_deployment_configuration error without reflecting database credentials,
  # TLS paths or raw parsing exceptions.

  # @cc [owner:ghuntley,label:recovery] abandoned-transaction-server-deadline
  # Production Repo sessions MUST ask PostgreSQL to terminate transactions idle
  # for 15 seconds. Loss of the client machine MUST NOT leave its unfinished
  # transaction holding locks indefinitely. Client-side timeouts alone do not
  # establish this guarantee; an uncertain commit still requires idempotent retry.

  # @cc [owner:ghuntley,label:recovery;capacity] lost-client-connections-are-reclaimed
  # Production TCP sessions MUST request 15-second idle keepalives, 5-second
  # retries, three missed probes and a 15-second unacknowledged-data limit.
  # Lost client machines MUST NOT accumulate idle Repo/notifier connections
  # indefinitely across restarts; healthy idle sessions must remain usable.

  # @cc [owner:ghuntley,label:recovery] lost-active-database-clients-are-observed
  # Production Repo connections MUST check for client loss during active
  # statements once per second. This MUST NOT impose a statement-duration limit
  # or authorize replay of an uncertain commit. The native convoy fixture must
  # retain its independent holder and all-connection reclamation deadlines.
  @spec from_env(map()) :: {:ok, t()} | {:error, :invalid_deployment_configuration}
  def from_env(env) do
    with {:ok, database} <- database(env),
         {:ok, replicas} <- integer(env, "MARSHALL_REPLICA_COUNT", nil, 1..100),
         {:ok, pool} <- integer(env, "POOL_SIZE", "10", 1..100),
         {:ok, budget} <- integer(env, "MARSHALL_DB_CONNECTION_BUDGET", nil, 1..100_000),
         true <- replicas * (pool + 1) + @operator_headroom <= budget,
         id when is_binary(id) <- env["MARSHALL_INSTANCE_ID"],
         true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, id),
         {:ok, endpoint} <- endpoint(env),
         {:ok, fleet_listeners} <- fleet_listeners(env, endpoint) do
      {:ok,
       %__MODULE__{
         repo:
           Keyword.merge(database,
             pool_size: pool,
             pool_count: 1,
             parameters: [
               application_name: "marshall:" <> id,
               synchronous_commit: "on",
               idle_in_transaction_session_timeout: "15s",
               client_connection_check_interval: "1s",
               tcp_keepalives_idle: "15s",
               tcp_keepalives_interval: "5s",
               tcp_keepalives_count: "3",
               tcp_user_timeout: "15s"
             ],
             connect_timeout: 3000,
             handshake_timeout: 3000,
             target_server_type: :primary,
             show_sensitive_data_on_connection_error: false
           ),
         endpoint: endpoint,
         fleet_listeners: fleet_listeners,
         replicas: replicas,
         connection_budget: budget,
         instance_id: id
       }}
    else
      _ -> {:error, :invalid_deployment_configuration}
    end
  rescue
    _ -> {:error, :invalid_deployment_configuration}
  end

  # @cc [owner:ghuntley,label:security] runtime-database-url-no-overrides
  # Database URLs MUST NOT contain query/fragment overrides or supply arbitrary
  # Repo options. Only validated host, port, username, password and database may
  # enter the separately enforced transport/pool configuration.
  defp database(env) do
    url = env["DATABASE_URL"]

    with true <- is_binary(url) and byte_size(url) in 1..16_384,
         {:ok, uri} <- URI.new(url),
         true <-
           uri.scheme in ["ecto", "postgres", "postgresql"] and
             is_nil(uri.query) and is_nil(uri.fragment),
         parsed = Ecto.Repo.Supervisor.parse_url(url),
         host when is_binary(host) and byte_size(host) in 1..253 <- parsed[:hostname],
         true <- clean?(host) and clean?(parsed[:username]) and clean?(parsed[:database]),
         port = parsed[:port] || 5432,
         true <- is_integer(port) and port in 1..65_535,
         {:ok, ssl} <- database_tls(env, host),
         {:ok, socket_options} <- socket_options(env, host) do
      {:ok,
       parsed
       |> Keyword.take([:hostname, :username, :password, :database])
       |> Keyword.put_new(:password, "")
       |> Keyword.merge(port: port, ssl: ssl, socket_options: socket_options)}
    else
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] runtime-database-ipv4-only
  # Database transport MUST force IPv4 for DNS names and reject IPv6 literals
  # and requests to enable IPv6 before constructing a Repo configuration.
  defp socket_options(env, host) do
    if Map.get(env, "ECTO_IPV6", "false") == "false" and not String.contains?(host, ":"),
      do: {:ok, [:inet]},
      else: :error
  end

  # @cc [owner:ghuntley,label:security] runtime-postgres-verified-tls
  # PostgreSQL MUST default to peer and hostname-verified TLS 1.2/1.3. Plaintext
  # requires explicit loopback mode and a literal localhost/127.0.0.1 host;
  # other insecure modes or nonloopback destinations MUST be rejected.
  defp database_tls(env, host) do
    case Map.get(env, "MARSHALL_DB_TLS", "verify") do
      "verify" ->
        ca = Map.get(env, "MARSHALL_DB_CA_CERTFILE", CAStore.file_path())

        if absolute_file?(ca),
          do:
            {:ok,
             [
               verify: :verify_peer,
               cacertfile: String.to_charlist(ca),
               versions: [:"tlsv1.2", :"tlsv1.3"],
               server_name_indication: String.to_charlist(host),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]},
          else: :error

      "loopback" when host in ["localhost", "127.0.0.1"] ->
        {:ok, false}

      _ ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:security] runtime-serving-needs-https
  # A serving instance MUST supply paired TLS certificate/key files and valid
  # IPv4 listener ports; an optional HTTP listener MUST use a different port. Bind
  # loopback by default until an operator explicitly configures another address.
  defp endpoint(env) do
    server = Map.get(env, "PHX_SERVER", "false")

    with true <- server in ["true", "false"],
         address when is_binary(address) <- Map.get(env, "MARSHALL_BIND_IP", "127.0.0.1"),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         {:ok, http} <- http(env, ip),
         {:ok, https} <- https(env, ip, server == "true"),
         true <- http == false or https == false or http[:port] != https[:port] do
      {:ok, [server: server == "true", http: http, https: https]}
    else
      _ -> :error
    end
  end

  defp http(%{"PORT" => _} = env, ip) do
    with {:ok, port} <- integer(env, "PORT", nil, 1..65_535), do: {:ok, [ip: ip, port: port]}
  end

  defp http(_, _), do: {:ok, false}

  # @cc [owner:ghuntley,label:security] fleet-listener-separate-ipv4-tls
  # Serving fleet APIs MUST use a distinct IPv4 HTTPS socket, defaulting to
  # loopback. Wildcard fleet binds and collisions with either browser listener
  # MUST fail startup. Non-serving configuration MUST NOT start a fleet listener.
  # An additional loopback bind requires explicit opt-in and the same collision
  # checks; it MUST NOT replace the configured private listener after failure.
  defp fleet_listeners(env, endpoint) do
    with address when is_binary(address) <-
           Map.get(env, "MARSHALL_FLEET_BIND_IP", "127.0.0.1"),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         false <- ip == {0, 0, 0, 0},
         loopback when loopback in ["true", "false"] <-
           Map.get(env, "MARSHALL_FLEET_LOOPBACK", "false"),
         addresses = Enum.uniq([ip] ++ if(loopback == "true", do: [{127, 0, 0, 1}], else: [])),
         {:ok, port} <- integer(env, "MARSHALL_FLEET_TLS_PORT", "5443", 1..65_535),
         false <-
           Enum.any?([endpoint[:http], endpoint[:https]], fn
             false ->
               false

             listener ->
               listener[:port] == port and listener[:ip] in [{0, 0, 0, 0} | addresses]
           end) do
      if endpoint[:server] do
        {:ok,
         Enum.map(addresses, fn address ->
           Keyword.merge(endpoint[:https],
             ip: address,
             port: port,
             scheme: :https,
             plug: MarshallWeb.FleetEndpoint
           )
         end)}
      else
        {:ok, []}
      end
    else
      _ -> :error
    end
  end

  defp https(env, ip, serving?) do
    case {env["MARSHALL_TLS_CERTFILE"], env["MARSHALL_TLS_KEYFILE"]} do
      {nil, nil} when not serving? ->
        {:ok, false}

      {cert, key} ->
        with true <- absolute_file?(cert) and absolute_file?(key),
             {:ok, port} <- integer(env, "MARSHALL_TLS_PORT", "4443", 1..65_535) do
          {:ok,
           [
             ip: ip,
             port: port,
             certfile: cert,
             keyfile: key,
             thousand_island_options: [transport_options: [versions: [:"tlsv1.2", :"tlsv1.3"]]]
           ]}
        else
          _ -> :error
        end
    end
  end

  defp integer(env, key, default, range) do
    case Map.get(env, key, default) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} -> if number in range, do: {:ok, number}, else: :error
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp clean?(value),
    do:
      is_binary(value) and byte_size(value) in 1..253 and
        String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp absolute_file?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.regular?(path)
end
