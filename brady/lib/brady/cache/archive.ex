defmodule Brady.Cache.Archive do
  @moduledoc "Built-in public, commit-pinned GitHub archive policy; never a transport exception."
  alias Brady.Cache.Policy

  @path ~r/\A\/[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}\/(?:tar\.gz|legacy\.tar\.gz)\/[0-9a-f]{40}\z/

  # @cc [owner:ghuntley,label:security] brady-public-pinned-archive
  # Only anonymous verified-HTTPS codeload archive requests at port 443 with
  # canonical owner/repository/full-commit paths may receive inferred public
  # freshness. This predicate MUST NOT authorize sockets, TLS or private data.
  @spec eligible?(Policy.request()) :: boolean()
  def eligible?(request) do
    request.scheme == :https and request.port == 443 and
      String.downcase(request.host) == "codeload.github.com" and
      Regex.match?(@path, request.target) and
      not Enum.any?(String.split(request.target, "/"), &(&1 in [".", ".."])) and
      Policy.eligible?(request)
  end

  # @cc [owner:ghuntley,label:security] brady-archive-normalization
  # Normalization MUST preserve private/no-store refusals and every unsupported
  # Vary field. Authorization Vary may be removed only for an anonymous archive;
  # all remaining variant fields MUST retain their ordinary policy checks.
  @spec headers(Policy.request(), Policy.headers()) :: Policy.headers()
  def headers(request, headers) do
    if eligible?(request) do
      control = Policy.values(headers, "cache-control")

      headers =
        case control do
          [] ->
            headers ++ [{"cache-control", "public, max-age=3600"}]

          _ ->
            # The ordinary parser rejects private, no-store and ambiguous directives.
            flags =
              control
              |> Enum.join(",")
              |> String.downcase()
              |> String.split(",")
              |> Enum.map(&String.trim/1)

            if "public" in flags, do: headers, else: headers ++ [{"cache-control", "public"}]
        end

      fields =
        Policy.values(headers, "vary")
        |> Enum.join(",")
        |> String.split(",", trim: true)
        |> Enum.map(&(String.trim(&1) |> String.downcase()))

      if length(fields) == length(Enum.uniq(fields)) do
        Enum.reject(headers, fn {name, _} -> String.downcase(name) == "vary" end) ++
          [{"vary", Enum.reject(fields, &(&1 == "authorization")) |> Enum.join(",")}]
      else
        headers
      end
    else
      headers
    end
  end
end
