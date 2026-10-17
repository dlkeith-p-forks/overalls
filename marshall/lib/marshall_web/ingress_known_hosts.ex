defmodule MarshallWeb.IngressKnownHosts do
  @moduledoc "Public SSH key discovery backed by a freshly validated Audi route."
  import Plug.Conn

  # @cc [owner:ghuntley,label:security] ingress-public-current-key
  # A successful response MUST contain only the current route's registered key
  # under the configured application hostname. Actual HTTPS and canonical labels
  # are required; forwarded headers, query parameters and cookies MUST NOT choose
  # keys or zones. Missing, expired or unavailable authority MUST return no key.
  # Responses MUST prohibit caching and MUST NOT expose internal route metadata.
  @spec call(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def call(conn, label) do
    with :https <- conn.scheme,
         "GET" <- conn.method,
         "" <- conn.query_string,
         true <- OverallsProtocol.IngressName.valid_label?(label),
         zone when is_binary(zone) <- Application.get_env(:marshall, :ingress_zone),
         true <- valid_zone?(zone),
         host = label <> "." <> zone,
         true <- byte_size(host) <= 253,
         {:ok, route} <-
           Marshall.Ingress.current_route(%{label: label},
             actor: Marshall.Authorization.SystemActor.compute()
           ) do
      reply(conn, 200, host <> " " <> route.ssh_host_key <> "\n")
    else
      _ -> reply(conn, 404, "unavailable\n")
    end
  rescue
    _ -> reply(conn, 503, "unavailable\n")
  end

  # @cc [owner:ghuntley,label:security] inception-public-key-layers
  # Nested discovery MUST use actual HTTPS and exact fixed service/layer paths.
  # Keys and namespace MUST come from current domain authority and operator
  # configuration. Public output MUST contain only host aliases and public keys,
  # be non-cacheable, and never fall back to stale state or ordinary VM routes.
  @spec nested(Plug.Conn.t(), binary(), binary(), binary()) :: Plug.Conn.t()
  def nested(conn, label, service, layer) do
    with :https <- conn.scheme,
         "GET" <- conn.method,
         "" <- conn.query_string,
         true <- layer in ["gateway", "inner"],
         kind when not is_nil(kind) <- %{"porsche" => :porsche_ssh, "audi" => :audi_ssh}[service],
         zone when is_binary(zone) <- Application.get_env(:marshall, :ingress_zone),
         {:ok, origins} <- OverallsProtocol.InceptionName.origins(label, zone),
         {:ok, current} <-
           Marshall.Ingress.current_nested_ssh(
             %{label: label, nested_service: kind},
             actor: Marshall.Authorization.SystemActor.compute()
           ) do
      host = if(layer == "gateway", do: "gateway", else: service) <> "." <> origins.namespace
      keys = if layer == "gateway", do: current.gateway_keys, else: [current.host_key]
      reply(conn, 200, Enum.map_join(keys, "", &(host <> " " <> &1 <> "\n")))
    else
      _ -> reply(conn, 404, "unavailable\n")
    end
  rescue
    _ -> reply(conn, 503, "unavailable\n")
  end

  @spec valid_zone?(term()) :: boolean()
  def valid_zone?(zone) when is_binary(zone) and byte_size(zone) in 1..189 do
    zone
    |> String.split(".")
    |> Enum.all?(&Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))
  end

  def valid_zone?(_), do: false

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, body)
    |> halt()
  end
end
