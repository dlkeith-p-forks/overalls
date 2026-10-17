defmodule Brady.TLS do
  @moduledoc "Guest TLS termination using supplied signing authority and retained ClientHello bytes."
  alias Brady.TLS.{Certificates, Hello}

  @spec accept(:gen_tcp.socket(), GenServer.server(), String.t()) ::
          {:ok, Brady.Transport.t(), String.t()} | {:error, :tls}
  def accept(socket, signer, default_host) do
    with {:ok, hello_host, wire} <- Hello.read(socket),
         host = hello_host || default_host,
         {:ok, options} <- Certificates.fetch(signer, host),
         :ok <- :gen_tcp.unrecv(socket, wire),
         {:ok, tls} <-
           :ssl.handshake(
             socket,
             options ++
               [
                 active: false,
                 mode: :binary,
                 alpn_preferred_protocols: ["http/1.1"],
                 versions: [:"tlsv1.3", :"tlsv1.2"],
                 verify: :verify_none,
                 log_level: :none
               ],
             5_000
           ) do
      {:ok, {:tls, tls}, host}
    else
      _ -> {:error, :tls}
    end
  rescue
    _ -> {:error, :tls}
  catch
    :exit, _ -> {:error, :tls}
  end
end
