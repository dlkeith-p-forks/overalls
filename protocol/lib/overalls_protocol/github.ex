defmodule OverallsProtocol.GitHub do
  @moduledoc "Closed routing and lease contracts for the built-in github-com integration."
  alias OverallsProtocol.Integration

  @name "com-github"
  @host "com-github.integration.internal"
  @origins %{
    "api" => "https://api.github.com",
    "uploads" => "https://uploads.github.com",
    "git" => "https://github.com",
    "gist" => "https://gist.github.com",
    "raw" => "https://raw.githubusercontent.com",
    "gist_raw" => "https://gist.githubusercontent.com",
    "capability" => "https://api.github.com"
  }
  @prefixes %{
    "api" => "/api",
    "uploads" => "/uploads",
    "git" => "/git",
    "gist" => "/gist",
    "raw" => "/raw",
    "gist_raw" => "/gist-raw"
  }
  @type kind :: :api | :uploads | :git | :gist | :raw | :gist_raw | :capability
  @type route :: %{kind: kind(), method: String.t(), path: String.t(), query: String.t()}
  @type lease ::
          :anonymous | %{id: String.t(), connection_id: String.t(), generation: pos_integer()}
  @type authorization :: %{
          target: String.t(),
          strip_prefix: nil,
          headers: [{String.t(), String.t()}],
          peer: nil,
          ttl: 500..5000,
          lease: lease()
        }

  @spec name() :: String.t()
  def name, do: @name
  @spec hostname() :: String.t()
  def hostname, do: @host
  @spec integration_type() :: String.t()
  def integration_type, do: "github-com"

  # @cc [owner:ghuntley,label:security;protocol] github-closed-origin-routing
  # Guest input MUST select one reviewed route, method and bounded path/query,
  # never an origin, credentials, a traversal segment or an arbitrary URL.
  # Transfers use only an opaque 256-bit selector; the edge independently binds
  # its read or LFS action method before dispatch.
  @spec route(term()) :: {:ok, route()} | {:error, :invalid_route}
  def route(%{"kind" => kind, "method" => method, "path" => path, "query" => query} = wire)
      when map_size(wire) == 4 do
    with true <- Map.has_key?(@origins, kind),
         true <- method_allowed?(kind, method),
         true <- path?(path),
         true <- query?(query),
         true <-
           kind != "capability" or
             (selector?(String.replace_prefix(path, "/", "")) and query == "") do
      {:ok, %{kind: kind_atom(kind), method: method, path: path, query: query}}
    else
      _ -> {:error, :invalid_route}
    end
  end

  def route(_), do: {:error, :invalid_route}

  @spec request(String.t(), String.t(), String.t()) :: {:ok, route()} | {:error, :invalid_route}
  def request(method, path, query) when is_binary(path) do
    case Enum.find(@prefixes, fn {_kind, prefix} ->
           path == prefix or String.starts_with?(path, prefix <> "/")
         end) do
      {kind, prefix} ->
        upstream_path = String.replace_prefix(path, prefix, "")

        route(%{
          "kind" => kind,
          "method" => method,
          "path" => if(upstream_path == "", do: "/", else: upstream_path),
          "query" => query
        })

      nil ->
        case path do
          "/capabilities/" <> selector ->
            route(%{
              "kind" => "capability",
              "method" => method,
              "path" => "/" <> selector,
              "query" => query
            })

          _ ->
            {:error, :invalid_route}
        end
    end
  end

  def request(_, _, _), do: {:error, :invalid_route}

  @spec encode_route(route()) :: map()
  def encode_route(route),
    do: %{
      "kind" => Atom.to_string(route.kind),
      "method" => route.method,
      "path" => route.path,
      "query" => route.query
    }

  @spec origin(kind()) :: String.t()
  def origin(kind), do: Map.fetch!(@origins, Atom.to_string(kind))

  @spec read_method?(term()) :: boolean()
  def read_method?(method), do: method in ["GET", "HEAD"]

  @spec selector?(term()) :: boolean()
  def selector?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, value)

  # @cc [owner:ghuntley,label:security] github-signed-download-allowlist
  # Only verified GitHub response locations may mint capabilities. Their URL
  # MUST use HTTPS, the default port, no userinfo/fragment and a reviewed
  # GitHub artifact host. Provider Authorization MUST never reach these hosts.
  @spec download_url(term()) :: {:ok, URI.t()} | {:error, :invalid_download}
  def download_url(value) when is_binary(value) and byte_size(value) <= 16_384 do
    with {:ok,
          %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil, path: path} =
            uri} <- URI.new(value),
         true <-
           host in [
             "objects.githubusercontent.com",
             "release-assets.githubusercontent.com",
             "github-releases.githubusercontent.com",
             "github-cloud.githubusercontent.com",
             "github-cloud.s3.amazonaws.com"
           ] or
             (is_binary(host) and
                Regex.match?(~r/\Aproductionresultssa[a-z0-9]+\.blob\.core\.windows\.net\z/, host)),
         true <- path?(path),
         true <- bounded_text?(uri.query || "", 16_384) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_download}
    end
  end

  def download_url(_), do: {:error, :invalid_download}

  # @cc [owner:ghuntley,label:security] github-lfs-action-targets
  # LFS action credentials MUST target only reviewed storage hosts or the fixed
  # GitHub smart-HTTP LFS namespace. Guest input cannot mint transfer authority.
  @spec transfer_url(term()) :: {:ok, URI.t()} | {:error, :invalid_download}
  def transfer_url(value) do
    case download_url(value) do
      {:ok, uri} ->
        {:ok, uri}

      _ ->
        with true <- is_binary(value) and byte_size(value) <= 16_384,
             {:ok,
              %URI{
                scheme: "https",
                host: "github.com",
                port: 443,
                userinfo: nil,
                fragment: nil,
                path: path
              } = uri} <- URI.new(value),
             true <- path?(path) and String.contains?(path, "/info/lfs/"),
             true <- bounded_text?(uri.query || "", 16_384) do
          {:ok, uri}
        else
          _ -> {:error, :invalid_download}
        end
    end
  end

  @spec credential_url?(term()) :: boolean()
  def credential_url?(value) when is_binary(value) do
    with {:ok, %URI{scheme: scheme, query: query}}
         when scheme in ["http", "https"] and is_binary(query) <- URI.new(value) do
      Regex.match?(
        ~r/(?:\A|&)(?:access_token|refresh_token|client_secret|authorization|token|sig|signature|jwt|x-amz-signature|x-amz-security-token|x-goog-signature)=/i,
        URI.decode(query)
      )
    else
      _ -> false
    end
  end

  def credential_url?(_), do: false

  @spec internal_url(term()) :: {:ok, String.t()} | {:error, :invalid_url}
  def internal_url(value) when is_binary(value) and byte_size(value) <= 16_384 do
    with {:ok, %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil} = uri} <-
           URI.new(value),
         {kind, _origin} <-
           Enum.find(@origins, fn {kind, origin} ->
             kind != "capability" and origin == "https://" <> (host || "")
           end),
         {:ok, _} <-
           route(%{
             "kind" => kind,
             "method" => "GET",
             "path" => uri.path || "/",
             "query" => uri.query || ""
           }) do
      {:ok,
       "https://" <>
         @host <>
         Map.fetch!(@prefixes, kind) <>
         (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def internal_url(_), do: {:error, :invalid_url}

  @spec authorization(term()) :: {:ok, authorization()} | {:error, :invalid_authorization}
  def authorization(%{"lease" => lease} = wire) when map_size(wire) == 5 do
    with {:ok, %{target: target, strip_prefix: nil, peer: nil} = base} <-
           Integration.authorization(Map.delete(wire, "lease")),
         true <- target in Map.values(@origins),
         {:ok, lease} <- lease(lease) do
      {:ok, Map.put(base, :lease, lease)}
    else
      _ -> {:error, :invalid_authorization}
    end
  end

  def authorization(_), do: {:error, :invalid_authorization}

  @spec lease(term()) :: {:ok, lease()} | {:error, :invalid_lease}
  def lease(%{"kind" => "anonymous"} = value) when map_size(value) == 1, do: {:ok, :anonymous}

  def lease(
        %{
          "kind" => "connected",
          "id" => id,
          "connection_id" => connection,
          "generation" => generation
        } = value
      )
      when map_size(value) == 4 and is_integer(generation) and generation > 0 and
             generation <= 9_223_372_036_854_775_807 do
    if OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(connection),
      do: {:ok, %{id: id, connection_id: connection, generation: generation}},
      else: {:error, :invalid_lease}
  end

  def lease(_), do: {:error, :invalid_lease}

  @spec encode_lease(lease()) :: map()
  def encode_lease(:anonymous), do: %{"kind" => "anonymous"}

  def encode_lease(lease),
    do: %{
      "kind" => "connected",
      "id" => lease.id,
      "connection_id" => lease.connection_id,
      "generation" => lease.generation
    }

  @spec request_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def request_headers(headers) do
    allowed =
      ~w(accept content-type user-agent x-github-api-version x-requested-with git-protocol if-none-match if-modified-since if-match if-unmodified-since range)

    Enum.filter(headers, fn {name, value} -> name in allowed and header_value?(value, 4096) end)
  end

  @spec response_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def response_headers(headers) do
    allowed =
      ~w(content-type content-disposition content-range accept-ranges etag last-modified cache-control expires vary retry-after x-github-request-id x-ratelimit-limit x-ratelimit-remaining x-ratelimit-used x-ratelimit-reset x-ratelimit-resource x-oauth-scopes x-accepted-oauth-scopes deprecation sunset)

    Enum.filter(headers, fn {name, value} -> name in allowed and header_value?(value, 8192) end)
  end

  defp method_allowed?("capability", method), do: method in ["GET", "HEAD", "PUT", "POST"]
  defp method_allowed?(kind, method) when kind in ["raw", "gist_raw"], do: read_method?(method)

  defp method_allowed?(kind, method) when kind in ["git", "gist"],
    do: method in ["GET", "HEAD", "POST"]

  defp method_allowed?("uploads", method), do: method == "POST"
  defp method_allowed?("api", method), do: method in ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  defp method_allowed?(_, _), do: false

  defp path?(path) when is_binary(path) do
    bounded_text?(path, 8192) and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["\\", "?", "#"]) and
      not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, path) and
      Enum.all?(
        String.split(URI.decode(path), "/"),
        &(&1 not in [".", ".."] and not String.contains?(&1, ["\\", "\r", "\n", "\0"]))
      )
  end

  defp path?(_), do: false

  defp query?(query) when is_binary(query),
    do:
      bounded_text?(query, 8192) and not String.contains?(query, "#") and
        not credential_url?("https://api.github.com/?" <> query)

  defp query?(_), do: false

  defp bounded_text?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x20\x7f]/, value)

  defp header_value?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp kind_atom("api"), do: :api
  defp kind_atom("uploads"), do: :uploads
  defp kind_atom("git"), do: :git
  defp kind_atom("gist"), do: :gist
  defp kind_atom("raw"), do: :raw
  defp kind_atom("gist_raw"), do: :gist_raw
  defp kind_atom("capability"), do: :capability
end
