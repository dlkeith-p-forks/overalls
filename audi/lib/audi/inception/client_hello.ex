defmodule Audi.Inception.ClientHello do
  @moduledoc "Bounded TLS ClientHello inspection before termination or opaque forwarding."
  @maximum 65_536

  # @cc [owner:ghuntley,label:security] inception-clienthello-boundary
  # Inspection MUST finish within five seconds and at most 64 KiB, including
  # record framing. Only a complete ClientHello with one canonical DNS SNI is
  # accepted. Fragmented handshake records MUST preserve their original bytes;
  # malformed lengths, duplicate extensions/SNI and missing SNI MUST fail closed.
  @spec read(:gen_tcp.socket()) :: {:ok, binary(), binary()} | {:error, :invalid_client_hello}
  def read(socket), do: read(socket, now() + 5000)

  @spec read(:gen_tcp.socket(), integer()) ::
          {:ok, binary(), binary()} | {:error, :invalid_client_hello}
  def read(socket, deadline), do: records(socket, min(deadline, now() + 5000), <<>>, <<>>)

  defp records(socket, deadline, wire, handshake) do
    with true <- byte_size(wire) + 5 <= @maximum,
         {:ok, <<22, 3, minor, length::16>> = header} when minor in 1..3 and length in 1..16384 <-
           recv(socket, 5, deadline),
         true <- byte_size(wire) + 5 + length <= @maximum,
         {:ok, data} <- recv(socket, length, deadline) do
      wire = wire <> header <> data
      handshake = handshake <> data

      case handshake do
        <<1, size::24, body::binary>> when size > 0 and size <= @maximum - 4 ->
          if byte_size(body) >= size do
            <<hello::binary-size(^size), _::binary>> = body

            case parse(hello) do
              {:ok, name} -> {:ok, name, wire}
              _ -> invalid()
            end
          else
            records(socket, deadline, wire, handshake)
          end

        bytes when byte_size(bytes) < 4 ->
          records(socket, deadline, wire, handshake)

        _ ->
          invalid()
      end
    else
      _ -> invalid()
    end
  end

  @spec parse(binary()) :: {:ok, binary()} | {:error, :invalid_client_hello}
  def parse(<<3, minor, _random::binary-size(32), session_size, rest::binary>>)
      when minor in 1..3 and session_size <= 32 do
    with <<_session::binary-size(^session_size), cipher_size::16, rest::binary>> <- rest,
         true <- cipher_size >= 2 and rem(cipher_size, 2) == 0,
         <<_ciphers::binary-size(^cipher_size), compression_size, rest::binary>> <- rest,
         true <- compression_size > 0,
         <<_compression::binary-size(^compression_size), extension_size::16, extensions::binary>> <-
           rest,
         true <- extension_size == byte_size(extensions) and extension_size <= @maximum do
      extensions(extensions, %{}, nil)
    else
      _ -> invalid()
    end
  end

  def parse(_), do: invalid()

  defp extensions(<<>>, _, name) when is_binary(name), do: {:ok, name}

  defp extensions(<<kind::16, size::16, value::binary-size(size), rest::binary>>, seen, name) do
    if Map.has_key?(seen, kind) do
      invalid()
    else
      if kind == 0 do
        case value do
          <<list_size::16, 0, length::16, host::binary-size(length)>>
          when list_size == length + 3 ->
            if hostname?(host),
              do: extensions(rest, Map.put(seen, kind, true), host),
              else: invalid()

          _ ->
            invalid()
        end
      else
        extensions(rest, Map.put(seen, kind, true), name)
      end
    end
  end

  defp extensions(_, _, _), do: invalid()

  defp hostname?(name) do
    byte_size(name) in 1..253 and
      Enum.all?(
        String.split(name, "."),
        &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
      )
  end

  defp recv(socket, length, deadline) do
    remaining = deadline - now()
    if remaining > 0, do: :gen_tcp.recv(socket, length, remaining), else: invalid()
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp invalid, do: {:error, :invalid_client_hello}
end
