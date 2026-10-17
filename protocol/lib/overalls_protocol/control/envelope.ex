defmodule OverallsProtocol.Control.Envelope do
  @moduledoc """
  Message envelope of the OverallsProtocol control WebSocket (version 1).

  Every control message is one JSON text frame with a closed kind `k`:

      hello   {k, v, service, bind}          client -> server, first frame
      welcome {k, conn, heartbeat_ms, limits} server -> client
      req     {k, id, op, body}              client -> server
      res     {k, id, ok: true, body}        server -> client
      res     {k, id, ok: false, error}      server -> client
      hint    {k, kind, id}                  server -> client
      resync  {k}                            server -> client
      ping    {k, n} / pong {k, n}           either direction

  Op names, hint kinds and errors stay strings here; each service maps them
  through its own closed table, so decoding never creates atoms.
  """

  @version 1
  @max_id 9_007_199_254_740_991
  @max_name 64

  @type message ::
          {:hello, %{version: pos_integer(), service: String.t(), bind: map()}}
          | {:welcome, %{conn: String.t(), heartbeat_ms: pos_integer(), limits: map()}}
          | {:req, %{id: non_neg_integer(), op: String.t(), body: map()}}
          | {:res, %{id: non_neg_integer(), result: {:ok, map()} | {:error, String.t()}}}
          | {:hint, %{kind: String.t(), id: String.t()}}
          | :resync
          | {:ping, non_neg_integer()}
          | {:pong, non_neg_integer()}

  @doc "The one supported protocol version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Encodes a message as a JSON text payload."
  @spec encode(message()) :: binary()
  def encode({:hello, %{service: service, bind: bind}}),
    do: JSON.encode!(%{"k" => "hello", "v" => @version, "service" => service, "bind" => bind})

  def encode({:welcome, %{conn: conn, heartbeat_ms: heartbeat, limits: limits}}),
    do:
      JSON.encode!(%{
        "k" => "welcome",
        "conn" => conn,
        "heartbeat_ms" => heartbeat,
        "limits" => limits
      })

  def encode({:req, %{id: id, op: op, body: body}}),
    do: JSON.encode!(%{"k" => "req", "id" => id, "op" => op, "body" => body})

  def encode({:res, %{id: id, result: {:ok, body}}}),
    do: JSON.encode!(%{"k" => "res", "id" => id, "ok" => true, "body" => body})

  def encode({:res, %{id: id, result: {:error, error}}}),
    do: JSON.encode!(%{"k" => "res", "id" => id, "ok" => false, "error" => error})

  def encode({:hint, %{kind: kind, id: id}}),
    do: JSON.encode!(%{"k" => "hint", "kind" => kind, "id" => id})

  def encode(:resync), do: JSON.encode!(%{"k" => "resync"})
  def encode({:ping, n}), do: JSON.encode!(%{"k" => "ping", "n" => n})
  def encode({:pong, n}), do: JSON.encode!(%{"k" => "pong", "n" => n})

  # @cc [owner:ghuntley,label:protocol;security] control-envelope-closed
  # decode/1 MUST accept only the closed kinds with exactly their fields,
  # bounded identifiers and names, and object bodies, and MUST answer a hello
  # for any other version with :unsupported_version. It never creates atoms.
  @doc "Decodes one JSON text payload."
  @spec decode(binary()) :: {:ok, message()} | {:error, :invalid_message | :unsupported_version}
  def decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"k" => kind} = map} when is_binary(kind) -> message(kind, map)
      _ -> {:error, :invalid_message}
    end
  end

  @spec message(String.t(), map()) ::
          {:ok, message()} | {:error, :invalid_message | :unsupported_version}
  defp message("hello", %{"v" => v} = map) when map_size(map) == 4 and v != @version do
    if is_integer(v), do: {:error, :unsupported_version}, else: {:error, :invalid_message}
  end

  defp message("hello", %{"v" => @version, "service" => service, "bind" => bind} = map)
       when map_size(map) == 4 and is_map(bind) do
    if name?(service),
      do: {:ok, {:hello, %{version: @version, service: service, bind: bind}}},
      else: {:error, :invalid_message}
  end

  defp message(
         "welcome",
         %{"conn" => conn, "heartbeat_ms" => heartbeat, "limits" => limits} = map
       )
       when map_size(map) == 4 and is_binary(conn) and is_integer(heartbeat) and heartbeat > 0 and
              is_map(limits),
       do: {:ok, {:welcome, %{conn: conn, heartbeat_ms: heartbeat, limits: limits}}}

  defp message("req", %{"id" => id, "op" => op, "body" => body} = map)
       when map_size(map) == 4 and is_map(body) do
    if id?(id) and name?(op),
      do: {:ok, {:req, %{id: id, op: op, body: body}}},
      else: {:error, :invalid_message}
  end

  defp message("res", %{"id" => id, "ok" => true, "body" => body} = map)
       when map_size(map) == 4 and is_map(body) do
    if id?(id),
      do: {:ok, {:res, %{id: id, result: {:ok, body}}}},
      else: {:error, :invalid_message}
  end

  defp message("res", %{"id" => id, "ok" => false, "error" => error} = map)
       when map_size(map) == 4 do
    if id?(id) and name?(error),
      do: {:ok, {:res, %{id: id, result: {:error, error}}}},
      else: {:error, :invalid_message}
  end

  defp message("hint", %{"kind" => kind, "id" => id} = map) when map_size(map) == 3 do
    if name?(kind) and uuid?(id),
      do: {:ok, {:hint, %{kind: kind, id: id}}},
      else: {:error, :invalid_message}
  end

  defp message("resync", map) when map_size(map) == 1, do: {:ok, :resync}

  defp message(kind, %{"n" => n} = map) when kind in ["ping", "pong"] and map_size(map) == 2 do
    if id?(n), do: {:ok, {String.to_existing_atom(kind), n}}, else: {:error, :invalid_message}
  end

  defp message(_kind, _map), do: {:error, :invalid_message}

  @spec id?(term()) :: boolean()
  defp id?(id), do: is_integer(id) and id >= 0 and id <= @max_id

  @spec name?(term()) :: boolean()
  defp name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..@max_name and
        String.match?(name, ~r/\A[a-z][a-z0-9_.]*\z/)

  @spec uuid?(term()) :: boolean()
  defp uuid?(id), do: is_binary(id) and OverallsProtocol.uuid?(id)
end
