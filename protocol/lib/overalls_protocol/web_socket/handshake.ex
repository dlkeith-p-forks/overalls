defmodule OverallsProtocol.WebSocket.Handshake do
  @moduledoc "Pure client side of the RFC 6455 opening handshake (bounded, no extensions)."

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @max_head 8192

  @type headers :: [{String.t(), String.t()}]

  @doc "A fresh random `Sec-WebSocket-Key`."
  @spec key() :: String.t()
  def key, do: Base.encode64(:crypto.strong_rand_bytes(16))

  @doc "The upgrade request for `host` and `path` with extra header pairs."
  @spec request(String.t(), String.t(), String.t(), headers()) :: iodata()
  def request(host, path, key, headers) do
    [
      "GET /",
      String.trim_leading(path, "/"),
      " HTTP/1.1\r\nHost: ",
      host,
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
      key,
      "\r\nSec-WebSocket-Version: 13\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  # @cc [owner:ghuntley,label:protocol;security] websocket-handshake-bounded
  # response/2 MUST accept only a complete `HTTP/1.1 101` head of at most 8 KiB
  # whose Sec-WebSocket-Accept matches the key (constant-time comparison), and
  # MUST return any bytes after the head as the first frame data. Other
  # statuses are reported by code only, never with header or body text.
  @doc """
  Parses the server's response head from `buffer`.

  Returns `{:ok, rest}` after a valid 101, `:more` while incomplete,
  `{:error, {:status, code}}` for another status, or `{:error, :handshake_failed}`.
  """
  @spec response(binary(), String.t()) ::
          {:ok, binary()} | :more | {:error, :handshake_failed | {:status, 100..599}}
  def response(buffer, key) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] when byte_size(head) <= @max_head -> parse(head, key, rest)
      [_head, _rest] -> {:error, :handshake_failed}
      [_] when byte_size(buffer) > @max_head -> {:error, :handshake_failed}
      [_] -> :more
    end
  end

  @spec parse(binary(), String.t(), binary()) ::
          {:ok, binary()} | {:error, :handshake_failed | {:status, 100..599}}
  defp parse(head, key, rest) do
    [status | lines] = String.split(head, "\r\n")

    case status do
      "HTTP/1.1 101" <> _ ->
        if accept_matches?(lines, key), do: {:ok, rest}, else: {:error, :handshake_failed}

      <<"HTTP/1.1 ", code::binary-size(3), _::binary>> ->
        case Integer.parse(code) do
          {value, ""} when value in 100..599 -> {:error, {:status, value}}
          _ -> {:error, :handshake_failed}
        end

      _ ->
        {:error, :handshake_failed}
    end
  end

  @spec accept_matches?([String.t()], String.t()) :: boolean()
  defp accept_matches?(lines, key) do
    expected = Base.encode64(:crypto.hash(:sha, key <> @guid))

    Enum.any?(lines, fn line ->
      case :binary.split(line, ":") do
        [name, value] ->
          String.downcase(String.trim(name)) == "sec-websocket-accept" and
            constant_equal?(String.trim(value), expected)

        _ ->
          false
      end
    end)
  end

  @spec constant_equal?(binary(), binary()) :: boolean()
  defp constant_equal?(left, right),
    do: :crypto.hash_equals(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))

  @doc "The accept value a server would answer for `key` (used by tests)."
  @spec accept(String.t()) :: String.t()
  def accept(key), do: Base.encode64(:crypto.hash(:sha, key <> @guid))
end
