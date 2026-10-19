defmodule OverallsProtocol.TerminalAttach do
  @moduledoc """
  The SSH terminal attach contract (ADR-0223): Marshall's gateway stream route,
  its close codes, Porsche's single stderr header line and the closed exit
  status table that SSH clients such as Mila decode.

  Pure: no sockets, no atoms from peer text. The fixture
  `test/fixtures/terminal_attach.json` is the cross-language copy of this table.
  """

  @path "/api/terminal-gateway/v1/stream"
  @maximum_cursor 9_223_372_036_854_775_807

  @type mode :: :rw | :ro
  @type outcome :: :closed | :refused | :invalid | :authority | :transport
  @type error ::
          :invalid_command
          | :attach_requires_pty
          | :approval_required
          | :unauthorized
          | :authority_credential
          | :forbidden
          | :not_found
          | :terminal_unavailable
          | :conflict
          | :temporarily_unavailable
          | :transport_error
  @type attached :: %{
          from: non_neg_integer(),
          replay_bytes: non_neg_integer(),
          mode: mode()
        }
  @type header :: {:attached, attached()} | {:refused, error()}

  @errors %{
    "invalid_command" => :invalid_command,
    "attach_requires_pty" => :attach_requires_pty,
    "approval_required" => :approval_required,
    "unauthorized" => :unauthorized,
    "authority_credential" => :authority_credential,
    "forbidden" => :forbidden,
    "not_found" => :not_found,
    "terminal_unavailable" => :terminal_unavailable,
    "conflict" => :conflict,
    "temporarily_unavailable" => :temporarily_unavailable,
    "transport_error" => :transport_error
  }

  @doc "The fleet-listener route Porsche upgrades for one attachment."
  @spec path() :: String.t()
  def path, do: @path

  @doc "Request header carrying the single-use terminal ticket."
  @spec ticket_header() :: String.t()
  def ticket_header, do: "overalls-terminal-ticket"

  @doc "Request header carrying the attaching connection's SSH session credential."
  @spec session_header() :: String.t()
  def session_header, do: "overalls-ssh-session"

  @doc "The closed error names a refusal header may carry."
  @spec errors() :: [String.t()]
  def errors, do: @errors |> Map.keys() |> Enum.sort()

  @doc "The request path with replay cursor and initial geometry."
  @spec stream_path(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def stream_path(cursor, cols, rows)
      when is_integer(cursor) and cursor in 0..@maximum_cursor and is_integer(cols) and
             cols in 0..4096 and is_integer(rows) and rows in 0..512 do
    @path <> "?" <> URI.encode_query(cursor: cursor, cols: cols, rows: rows)
  end

  # @cc [owner:ghuntley,label:protocol] terminal-attach-exit-table
  # Exit statuses MUST stay the closed table: 0 the session closed or the
  # client detached, 1 Marshall refused the attachment, 2 the invocation was
  # invalid (including a missing PTY), 3 account/key/session authority failed
  # or was revoked, 5 transport or service failure. Unknown outcomes MUST NOT
  # exist; every close code and refusal maps to exactly one outcome.
  @doc "The SSH exit status for an outcome."
  @spec exit_status(outcome()) :: 0 | 1 | 2 | 3 | 5
  def exit_status(:closed), do: 0
  def exit_status(:refused), do: 1
  def exit_status(:invalid), do: 2
  def exit_status(:authority), do: 3
  def exit_status(:transport), do: 5

  @doc "The outcomes in exit-status order."
  @spec outcomes() :: [outcome()]
  def outcomes, do: [:closed, :refused, :invalid, :authority, :transport]

  @doc "The WebSocket close code Marshall sends for an outcome of a gateway stream."
  @spec close_code(outcome()) :: 1000 | 4001 | 4003 | 1008 | 1011
  def close_code(:closed), do: 1000
  def close_code(:authority), do: 4001
  def close_code(:refused), do: 4003
  def close_code(:invalid), do: 1008
  def close_code(:transport), do: 1011

  @doc "The outcome a received close code (or a missing one) denotes."
  @spec close_outcome(term()) :: outcome()
  def close_outcome(1000), do: :closed
  def close_outcome(4001), do: :authority
  def close_outcome(4003), do: :refused
  def close_outcome(_), do: :transport

  @doc "The outcome of an upgrade refused with an HTTP status."
  @spec status_outcome(term()) :: outcome()
  def status_outcome(401), do: :authority
  def status_outcome(status) when status in [400, 403, 404], do: :refused
  def status_outcome(_), do: :transport

  @doc "The outcome of a refusal error."
  @spec error_outcome(error()) :: outcome()
  def error_outcome(error) when error in [:invalid_command, :attach_requires_pty], do: :invalid

  def error_outcome(error)
      when error in [:approval_required, :unauthorized, :authority_credential],
      do: :authority

  def error_outcome(error)
      when error in [:forbidden, :not_found, :terminal_unavailable, :conflict],
      do: :refused

  def error_outcome(_error), do: :transport

  # @cc [owner:ghuntley,label:protocol;security] terminal-attach-single-header
  # A gateway MUST write exactly one header line on stderr per attach: either
  # the attached object (from, replay_bytes, mode) or a refusal naming only a
  # closed error. It never carries tickets, tokens, identities or terminal data.
  @doc "Encodes the stderr header line, newline-terminated."
  @spec encode(header()) :: String.t()
  def encode({:attached, %{from: from, replay_bytes: replay, mode: mode}})
      when is_integer(from) and from in 0..@maximum_cursor and is_integer(replay) and
             replay >= 0 and mode in [:rw, :ro] do
    JSON.encode!(%{
      "version" => 1,
      "attached" => true,
      "from" => from,
      "replay_bytes" => replay,
      "mode" => Atom.to_string(mode)
    }) <> "\n"
  end

  def encode({:refused, error}) when is_atom(error) do
    name = Atom.to_string(error)
    true = Map.has_key?(@errors, name)
    JSON.encode!(%{"version" => 1, "attached" => false, "error" => name}) <> "\n"
  end

  @doc "Decodes one header line; anything outside the closed schema is invalid."
  @spec decode(term()) :: {:ok, header()} | {:error, :invalid_header}
  def decode(line) when is_binary(line) and byte_size(line) <= 512 do
    case JSON.decode(String.trim_trailing(line, "\n")) do
      {:ok,
       %{
         "version" => 1,
         "attached" => true,
         "from" => from,
         "replay_bytes" => replay,
         "mode" => mode
       } = value}
      when map_size(value) == 5 and is_integer(from) and from in 0..@maximum_cursor and
             is_integer(replay) and replay >= 0 and mode in ["rw", "ro"] ->
        {:ok,
         {:attached,
          %{from: from, replay_bytes: replay, mode: if(mode == "rw", do: :rw, else: :ro)}}}

      {:ok, %{"version" => 1, "attached" => false, "error" => name} = value}
      when map_size(value) == 3 and is_binary(name) ->
        case Map.fetch(@errors, name) do
          {:ok, error} -> {:ok, {:refused, error}}
          :error -> {:error, :invalid_header}
        end

      _ ->
        {:error, :invalid_header}
    end
  end

  def decode(_line), do: {:error, :invalid_header}

  @doc "The closed error for a refusal name, or `:transport_error` when unknown."
  @spec error(term()) :: error()
  def error(name) when is_binary(name), do: Map.get(@errors, name, :transport_error)
  def error(name) when is_atom(name), do: error(Atom.to_string(name))
  def error(_name), do: :transport_error
end
