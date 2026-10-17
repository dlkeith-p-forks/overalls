defmodule Audi.Inception.Peer do
  @moduledoc "IPv4 metadata admitted only on a configured parent connector path."
  alias ThousandIsland.Socket

  # @cc [owner:ghuntley,label:security] inception-trusted-client-peer
  # Only the configured parent IPv4 may supply a PROXY header. Its destination
  # MUST equal this accepted socket's local address/port. Public listeners MUST
  # NOT consume PROXY metadata. Same-address local readiness probes may omit the
  # header but MUST retain their actual peer identity, never a claimed one.
  @spec read(Socket.t(), :inet.ip4_address() | nil) ::
          {:ok, tuple() | nil} | {:error, :invalid_proxy_header}
  def read(_, nil), do: {:ok, nil}

  def read(socket, expected) when is_tuple(expected) and tuple_size(expected) == 4 do
    with {:ok, {peer, _}} <- Socket.peername(socket),
         {:ok, {local, _} = destination} <- Socket.sockname(socket) do
      cond do
        peer == expected ->
          with {:ok, bytes} <- Socket.recv(socket, 28, 1000),
               {:ok, %{source: source, destination: ^destination}} <-
                 OverallsProtocol.ProxyHeader.decode(bytes) do
            {:ok, source}
          else
            _ -> {:error, :invalid_proxy_header}
          end

        peer == local ->
          {:ok, nil}

        true ->
          {:error, :invalid_proxy_header}
      end
    else
      _ -> {:error, :invalid_proxy_header}
    end
  end

  def read(_, _), do: {:error, :invalid_proxy_header}
end
