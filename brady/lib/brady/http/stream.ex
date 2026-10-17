defmodule Brady.HTTP.Stream do
  @moduledoc "Backpressured HTTP/1 body forwarding; framing is checked before bytes are forwarded."
  alias Brady.{HTTP.Head, Transport}
  @chunk 65_536
  @type sink :: (binary() -> :ok | {:error, atom()})
  @type result :: {:ok, binary(), non_neg_integer()} | {:error, atom()}

  @spec head(Transport.t(), :request | :response, binary()) ::
          {:ok, Head.head(), binary()} | {:error, atom()}
  def head(socket, kind, buffer \\ "") do
    case Head.parse(buffer, kind) do
      :more ->
        with {:ok, data} <- Transport.recv(socket), do: head(socket, kind, buffer <> data)

      result ->
        result
    end
  end

  # @cc [owner:ghuntley,label:security] brady-stream-bounded-exact-framing
  # Forwarding MUST wait for each sink write before reading more body data.
  # Fixed lengths and chunk terminators MUST be satisfied exactly; premature
  # close MUST fail. Body chunks sent to sinks MUST be at most 64 KiB, and
  # unbounded peer chunk sizes MUST NOT become allocation sizes.
  @type observation :: {:payload, binary()} | :trailers
  @type observer :: (observation() -> :ok)

  @spec body(Transport.t(), term(), binary(), sink()) :: result()
  def body(socket, framing, buffer, sink),
    do: body(socket, framing, buffer, sink, fn _ -> :ok end)

  # @cc [owner:ghuntley,label:verification] brady-stream-payload-observer
  # The observer MUST receive only decoded payload, in chunks at most 64 KiB,
  # and a trailers marker before completion when any trailer is present. Transfer
  # framing MUST reach only the wire sink; malformed completion MUST fail.
  @spec body(Transport.t(), term(), binary(), sink(), observer()) :: result()
  def body(_socket, :none, buffer, _sink, _observer), do: {:ok, buffer, 0}

  def body(socket, {:length, size}, buffer, sink, observer),
    do: fixed(socket, size, buffer, sink, observer, 0)

  def body(socket, :chunked, buffer, sink, observer),
    do: chunks(socket, buffer, sink, observer, 0)

  def body(socket, :close, buffer, sink, _observer), do: until_close(socket, buffer, sink, 0)

  defp fixed(_socket, 0, buffer, _sink, _observer, total), do: {:ok, buffer, total}

  defp fixed(socket, remaining, "", sink, observer, total) do
    with {:ok, data} <- Transport.recv(socket, min(remaining, @chunk)),
         do: fixed(socket, remaining, data, sink, observer, total)
  end

  defp fixed(socket, remaining, buffer, sink, observer, total) do
    take = min(min(remaining, byte_size(buffer)), @chunk)
    <<part::binary-size(^take), rest::binary>> = buffer

    with :ok <- observer.({:payload, part}),
         :ok <- sink.(part),
         do: fixed(socket, remaining - take, rest, sink, observer, total + take)
  end

  defp chunks(socket, buffer, sink, observer, total) do
    with {:ok, line, rest} <- line(socket, buffer, 1024),
         [hex | _extensions] <- String.split(line, ";", parts: 2),
         true <- Regex.match?(~r/\A[0-9A-Fa-f]{1,16}\z/, hex),
         {size, ""} <- Integer.parse(hex, 16) do
      if size == 0 do
        with {:ok, tail} <- trailers(socket, rest, 0, observer),
             :ok <- sink.("0\r\n\r\n"),
             do: {:ok, tail, total}
      else
        with :ok <- sink.(Integer.to_string(size, 16) <> "\r\n"),
             {:ok, rest, count} <- fixed(socket, size, rest, sink, observer, 0),
             {:ok, delimiter, tail} <- exact(socket, rest, 2),
             true <- delimiter == "\r\n",
             :ok <- sink.("\r\n") do
          chunks(socket, tail, sink, observer, total + count)
        else
          false -> {:error, :invalid_http}
          error -> error
        end
      end
    else
      false -> {:error, :invalid_http}
      :error -> {:error, :invalid_http}
      error -> error
    end
  end

  defp trailers(socket, buffer, consumed, observer) do
    with true <- consumed <= 16_384,
         {:ok, line, rest} <- line(socket, buffer, 8192) do
      if line == "" do
        {:ok, rest}
      else
        # Trailer fields cannot amend framing, authorization or cache policy.
        # They are intentionally discarded; malformed/folded fields fail closed.
        if Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+:[\x09\x20-\x7e]*\z/, line),
          do:
            (
              observer.(:trailers)
              trailers(socket, rest, consumed + byte_size(line) + 2, observer)
            ),
          else: {:error, :invalid_http}
      end
    else
      false -> {:error, :invalid_http}
      error -> error
    end
  end

  defp line(socket, buffer, maximum) do
    case :binary.match(buffer, "\r\n") do
      {length, 2} when length <= maximum ->
        <<value::binary-size(^length), _::binary-size(2), rest::binary>> = buffer
        {:ok, value, rest}

      :nomatch when byte_size(buffer) <= maximum ->
        with {:ok, data} <- Transport.recv(socket, 1), do: line(socket, buffer <> data, maximum)

      _ ->
        {:error, :invalid_http}
    end
  end

  defp exact(_socket, buffer, size) when byte_size(buffer) >= size do
    <<value::binary-size(^size), rest::binary>> = buffer
    {:ok, value, rest}
  end

  defp exact(socket, buffer, size) do
    with {:ok, data} <- Transport.recv(socket, size - byte_size(buffer)),
         do: exact(socket, buffer <> data, size)
  end

  defp until_close(socket, "", sink, total) do
    case Transport.recv(socket) do
      {:ok, bytes} -> until_close(socket, bytes, sink, total)
      {:error, :closed} -> {:ok, "", total}
      error -> error
    end
  end

  defp until_close(socket, buffer, sink, total) do
    take = min(@chunk, byte_size(buffer))
    <<part::binary-size(^take), rest::binary>> = buffer
    with :ok <- sink.(part), do: until_close(socket, rest, sink, total + take)
  end
end
