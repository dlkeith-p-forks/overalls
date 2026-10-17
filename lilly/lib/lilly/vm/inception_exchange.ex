defmodule Lilly.VM.InceptionExchange do
  @moduledoc "One bounded publication poll over the placement-owned Firecracker vsock."
  alias OverallsProtocol.{InceptionExchange, InceptionName}

  # @cc [owner:ghuntley,label:security] inception-exchange-owned-placement
  # Callers MUST derive the socket and boot expectation from the owned current
  # Inception placement and verify confined execution before and after polling.
  # This function MUST use only vsock port 1028, separate from guest flush and
  # SMTP, never their channels or TCP.
  # Parent credentials MUST NOT enter the request. A reply is evidence only,
  # never permission to publish or open a stream without current authority.

  # @cc [owner:ghuntley,label:security] inception-exchange-single-deadline
  # Connect, handshake, request and reply MUST share one monotonic deadline and
  # bounded framing. A reply for a previous request or boot MUST fail closed.
  @spec poll(
          Path.t(),
          OverallsProtocol.Readiness.expectation(),
          binary(),
          binary(),
          pos_integer(),
          pos_integer(),
          map() | nil,
          map() | nil,
          map() | nil
        ) ::
          {:ok, map()} | {:error, :inception_exchange_unavailable}
  def poll(
        path,
        boot,
        label,
        zone,
        generation,
        timeout,
        public \\ nil,
        observations \\ nil,
        parent \\ nil
      ) do
    with true <- path?(path) and is_integer(timeout) and timeout in 1..5000,
         {:ok, origins} <- InceptionName.origins(label, zone),
         {:ok, parent} <- OverallsProtocol.InceptionParent.validate(parent),
         true <- is_nil(parent) or (parent["label"] == label and parent["zone"] == zone),
         {:ok, public} <- OverallsProtocol.InceptionPublic.validate(public),
         {:ok, observations} <- OverallsProtocol.InceptionObservation.validate(observations),
         request_id = Lilly.UUID.generate(),
         binding = Map.new(boot, fn {key, value} -> {Atom.to_string(key), value} end),
         {:ok, _} <-
           InceptionExchange.encode(%{
             "version" => 1,
             "binding" => binding,
             "request_id" => request_id,
             "generation" => generation,
             "ttl_ms" => 5000,
             "porsche_host_key" => nil,
             "audi_host_key" => nil,
             "records" => []
           }),
         request =
           JSON.encode!(%{
             version: 1,
             binding: binding,
             request_id: request_id,
             generation: generation,
             origins: origins,
             public: public,
             observations: observations,
             parent: parent
           }),
         true <- byte_size(request) <= 65_536 do
      exchange(path, request, boot, request_id, generation, now() + timeout)
    else
      _ -> {:error, :inception_exchange_unavailable}
    end
  end

  defp exchange(path, request, boot, request_id, generation, deadline) do
    options = [:binary, active: false, packet: :line, packet_size: 64, send_timeout_close: true]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT #{InceptionExchange.port()}\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- handshake?(handshake),
               :ok <-
                 :inet.setopts(socket,
                   packet: 4,
                   packet_size: InceptionExchange.maximum(),
                   send_timeout: remaining(deadline)
                 ),
               :ok <- :gen_tcp.send(socket, request),
               {:ok, reply} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               {:ok, value} <- InceptionExchange.verify(reply, boot, request_id, generation),
               true <- remaining(deadline) > 0 do
            {:ok, value}
          else
            _ -> {:error, :inception_exchange_unavailable}
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        {:error, :inception_exchange_unavailable}
    end
  end

  defp handshake?("OK " <> suffix) when byte_size(suffix) <= 11 do
    case Integer.parse(suffix) do
      {port, "\n"} when port in 1..4_294_967_295 -> suffix == Integer.to_string(port) <> "\n"
      _ -> false
    end
  end

  defp handshake?(_), do: false

  defp path?(path) when is_binary(path) and byte_size(path) in 1..107,
    do:
      String.starts_with?(path, "/") and
        not Enum.any?(tl(String.split(path, "/")), &(&1 in ["", ".", ".."]))

  defp path?(_), do: false
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
