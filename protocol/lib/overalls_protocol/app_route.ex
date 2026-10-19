defmodule OverallsProtocol.AppRoute do
  @moduledoc """
  Canonical `overalls://HOST/PATH` application routes shared by Marshall and
  the Mila client (ADR-0221).

  Paths mirror Marshall's browser routes. The table is closed: any route not
  listed here is refused, every identifier is a canonical UUID and only the
  documented query keys are accepted. Routes never carry credentials.
  """

  alias OverallsProtocol.SSHHostCertificate
  alias OverallsProtocol.WorkspaceSource

  @scheme "overalls://"
  @maximum 2048

  @type uuid :: String.t()
  @type page ::
          :machines
          | {:machine, uuid()}
          | {:machine_info, uuid()}
          | {:machine_web, uuid()}
          | {:machine_terminals, uuid()}
          | {:machine_terminal, uuid(), uuid()}
          | {:machine_threads, uuid()}
          | {:machine_thread, uuid(), uuid()}
          | :threads
          | {:thread, uuid()}
          | {:launch, WorkspaceSource.t()}
          | {:ssh_approved, uuid()}
          | :settings
  @type t :: %{host: String.t(), port: 1..65_535 | nil, page: page()}

  # @cc [owner:ghuntley,label:security;protocol] app-route-closed-table
  # Application routes MUST be parsed against this closed table only. Parsing
  # MUST NOT raise or create atoms, MUST bound input to 2 KiB, and MUST refuse
  # userinfo, fragments, percent-encoded path segments, unknown query keys and
  # non-canonical identifiers. A route MUST NOT carry a secret.
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_route}
  def parse(value) when is_binary(value) and byte_size(value) <= @maximum do
    with true <- String.valid?(value),
         false <- String.contains?(value, "#"),
         false <- Regex.match?(~r/[\x00-\x20\x7f]/, value),
         @scheme <> rest <- value,
         {location, query} <- split_query(rest),
         false <- String.contains?(location, ["%", "@"]),
         [authority | segments] <- String.split(location, "/"),
         {:ok, host, port} <- authority(authority),
         {:ok, page} <- page(segments, query) do
      {:ok, %{host: host, port: port, page: page}}
    else
      _ -> {:error, :invalid_route}
    end
  end

  def parse(_), do: {:error, :invalid_route}

  @doc "Formats a route built from validated values into its canonical string."
  @spec format(t()) :: String.t()
  def format(%{host: host, port: port, page: page}) do
    authority = if port, do: host <> ":" <> Integer.to_string(port), else: host
    @scheme <> authority <> path(page)
  end

  @doc "Describes a route with string keys for cross-language fixture comparison."
  @spec describe(t()) :: %{String.t() => String.t() | non_neg_integer() | nil}
  def describe(%{host: host, port: port, page: page}) do
    Map.merge(%{"host" => host, "port" => port}, describe_page(page))
  end

  defp split_query(rest) do
    case String.split(rest, "?", parts: 2) do
      [location] -> {location, nil}
      [location, query] -> {location, query}
    end
  end

  defp authority(authority) do
    case String.split(authority, ":") do
      [host] ->
        if SSHHostCertificate.hostname?(host), do: {:ok, host, nil}, else: :error

      [host, port] ->
        with true <- SSHHostCertificate.hostname?(host),
             true <- Regex.match?(~r/\A[1-9][0-9]{0,4}\z/, port),
             value when value <= 65_535 <- String.to_integer(port) do
          {:ok, host, value}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp page(["machines"], nil), do: {:ok, :machines}
  defp page(["threads"], nil), do: {:ok, :threads}
  defp page(["settings"], nil), do: {:ok, :settings}
  defp page(["machines", id], nil), do: uuid_page(id, &{:machine, &1})
  defp page(["machines", id, "info"], nil), do: uuid_page(id, &{:machine_info, &1})
  defp page(["machines", id, "web"], nil), do: uuid_page(id, &{:machine_web, &1})
  defp page(["machines", id, "terminals"], nil), do: uuid_page(id, &{:machine_terminals, &1})
  defp page(["machines", id, "threads"], nil), do: uuid_page(id, &{:machine_threads, &1})

  defp page(["machines", id, "terminals", session], nil),
    do: pair_page(id, session, &{:machine_terminal, &1, &2})

  defp page(["machines", id, "threads", thread], nil),
    do: pair_page(id, thread, &{:machine_thread, &1, &2})

  defp page(["threads", id], nil), do: uuid_page(id, &{:thread, &1})

  defp page(["launch"], query) when is_binary(query) do
    with {:ok, url} <- single_query(query, "source"),
         {:ok, source} <- WorkspaceSource.parse_url(url) do
      {:ok, {:launch, source}}
    else
      _ -> :error
    end
  end

  defp page(["ssh", "approved"], query) when is_binary(query) do
    with {:ok, session} <- single_query(query, "session") do
      uuid_page(session, &{:ssh_approved, &1})
    end
  end

  defp page(_segments, _query), do: :error

  defp uuid_page(id, build),
    do: if(OverallsProtocol.uuid?(id), do: {:ok, build.(id)}, else: :error)

  defp pair_page(first, second, build) do
    if OverallsProtocol.uuid?(first) and OverallsProtocol.uuid?(second),
      do: {:ok, build.(first, second)},
      else: :error
  end

  defp single_query(query, key) do
    with [^key, encoded] <- String.split(query, "=", parts: 2),
         false <- String.contains?(encoded, ["&", "="]),
         {:ok, value} <- decode_component(encoded),
         true <- value != "" and String.valid?(value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp decode_component(encoded) do
    {:ok, URI.decode_www_form(encoded)}
  rescue
    ArgumentError -> :error
  end

  defp path(:machines), do: "/machines"
  defp path(:threads), do: "/threads"
  defp path(:settings), do: "/settings"
  defp path({:machine, id}), do: "/machines/" <> id
  defp path({:machine_info, id}), do: "/machines/" <> id <> "/info"
  defp path({:machine_web, id}), do: "/machines/" <> id <> "/web"
  defp path({:machine_terminals, id}), do: "/machines/" <> id <> "/terminals"
  defp path({:machine_terminal, id, session}), do: "/machines/" <> id <> "/terminals/" <> session
  defp path({:machine_threads, id}), do: "/machines/" <> id <> "/threads"
  defp path({:machine_thread, id, thread}), do: "/machines/" <> id <> "/threads/" <> thread
  defp path({:thread, id}), do: "/threads/" <> id

  defp path({:launch, source}),
    do: "/launch?source=" <> URI.encode_www_form(WorkspaceSource.to_url(source))

  defp path({:ssh_approved, session}), do: "/ssh/approved?session=" <> session

  defp describe_page(:machines), do: %{"page" => "machines"}
  defp describe_page(:threads), do: %{"page" => "threads"}
  defp describe_page(:settings), do: %{"page" => "settings"}
  defp describe_page({:machine, id}), do: %{"page" => "machine", "machine_id" => id}
  defp describe_page({:machine_info, id}), do: %{"page" => "machine_info", "machine_id" => id}
  defp describe_page({:machine_web, id}), do: %{"page" => "machine_web", "machine_id" => id}

  defp describe_page({:machine_terminals, id}),
    do: %{"page" => "machine_terminals", "machine_id" => id}

  defp describe_page({:machine_terminal, id, session}),
    do: %{"page" => "machine_terminal", "machine_id" => id, "session_id" => session}

  defp describe_page({:machine_threads, id}),
    do: %{"page" => "machine_threads", "machine_id" => id}

  defp describe_page({:machine_thread, id, thread}),
    do: %{"page" => "machine_thread", "machine_id" => id, "thread_id" => thread}

  defp describe_page({:thread, id}), do: %{"page" => "thread", "thread_id" => id}

  defp describe_page({:launch, source}),
    do: %{"page" => "launch", "source" => WorkspaceSource.to_url(source)}

  defp describe_page({:ssh_approved, session}),
    do: %{"page" => "ssh_approved", "session_id" => session}
end
