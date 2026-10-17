defmodule Brady.TLS.Hello do
  @moduledoc "Bounded ClientHello peek retaining exact wire bytes for an explicit tunnel or OTP handshake."
  alias Brady.{Destination, Transport}
  @spec read(:gen_tcp.socket()) :: {:ok, String.t() | nil, binary()} | {:error, :tls}
  def read(socket), do: records(socket, "", "", System.monotonic_time(:millisecond) + 5_000)

  # @cc [owner:ghuntley,label:security] brady-clienthello-bounds
  # ClientHello inspection MUST bound record and total handshake bytes, extract
  # at most one validated SNI, and retain exact wire bytes. A parsing failure
  # MUST NOT authorize an automatic uncached tunnel.
  defp records(socket, payload, wire, deadline) when byte_size(wire) <= 65_536 do
    with {:ok, <<22, 3, minor, length::16>> = header} <- receive_before(socket, 5, deadline),
         true <- minor in 0..3 and length in 1..16_384 and byte_size(wire) + length + 5 <= 65_536,
         {:ok, data} <- receive_before(socket, length, deadline) do
      payload = payload <> data
      wire = wire <> header <> data

      case payload do
        <<1, size::24, hello::binary>> when size <= 65_000 ->
          if byte_size(hello) >= size do
            <<body::binary-size(^size), _::binary>> = hello

            case hostname(body) do
              {:ok, host} -> {:ok, host, wire}
              _ -> {:error, :tls}
            end
          else
            records(socket, payload, wire, deadline)
          end

        _ when byte_size(payload) < 4 ->
          records(socket, payload, wire, deadline)

        _ ->
          {:error, :tls}
      end
    else
      _ -> {:error, :tls}
    end
  end

  defp records(_, _, _, _), do: {:error, :tls}

  defp receive_before(socket, length, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: Transport.recv({:tcp, socket}, length, remaining), else: {:error, :tls}
  end

  defp hostname(<<_version::16, _random::binary-size(32), session_size, rest::binary>>) do
    with <<_session::binary-size(^session_size), cipher_size::16, rest::binary>> <- rest,
         <<_ciphers::binary-size(^cipher_size), compression_size, rest::binary>> <- rest,
         <<_compression::binary-size(^compression_size), rest::binary>> <- rest do
      case rest do
        <<>> -> {:ok, nil}
        <<length::16, extensions::binary-size(length)>> -> extensions(extensions, nil)
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp hostname(_), do: :error

  defp extensions(<<>>, host), do: {:ok, host}

  defp extensions(<<0::16, size::16, value::binary-size(size), rest::binary>>, nil) do
    case value do
      <<list_size::16, list::binary-size(list_size)>> ->
        case list do
          <<0, name_size::16, name::binary-size(name_size)>> ->
            with {:ok, host} <- Destination.hostname(name), do: extensions(rest, host)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp extensions(<<0::16, _::binary>>, _), do: :error

  defp extensions(<<_type::16, size::16, _value::binary-size(size), rest::binary>>, host),
    do: extensions(rest, host)

  defp extensions(_, _), do: :error
end
