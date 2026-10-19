defmodule Marshall.AppRoutes do
  @moduledoc """
  Canonical `overalls://` links for this deployment (ADR-0221).

  Links name only public identifiers. They are offered to clients such as Mila
  so a result, notification or approval page can open the matching screen.
  """

  alias OverallsProtocol.AppRoute

  # @cc [owner:ghuntley,label:protocol;security] marshall-app-route-canonical
  # Marshall MUST emit only links that OverallsProtocol.AppRoute parses back to
  # the same route for the endpoint's public host; otherwise it emits nil.
  # Links MUST NOT carry tokens, approval paths or other secrets.
  @spec link(AppRoute.page()) :: String.t() | nil
  def link(page) do
    %URI{host: host, port: port} = URI.parse(MarshallWeb.Endpoint.url())
    route = %{host: host, port: if(port in [nil, 443], do: nil, else: port), page: page}

    with true <- is_binary(host),
         formatted = AppRoute.format(route),
         {:ok, ^route} <- AppRoute.parse(formatted) do
      formatted
    else
      _ -> nil
    end
  end
end
