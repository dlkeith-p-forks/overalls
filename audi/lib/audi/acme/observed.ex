defmodule Audi.ACME.Observed do
  @moduledoc "Boot-bound DNS proof readiness from the root-owned Inception broker."

  # @cc [owner:ghuntley,label:security] audi-proof-broker-runtime-binding
  # Runtime input MUST select only an exact boot binding and generation. It MUST
  # NOT select the broker path, peer UID or a destination. The TLS zone comes
  # from the caller's independently validated configuration.
  @spec new(term(), binary()) :: {:ok, map() | nil} | :error
  def new(nil, _), do: {:ok, nil}

  def new(%{"binding" => binding, "generation" => generation} = value, zone)
      when map_size(value) == 2 and is_map(binding) and map_size(binding) == 3 and
             is_integer(generation) and generation in 1..9_223_372_036_854_775_807 do
    with true <- Map.keys(binding) -- ~w(placement_id execution_epoch boot_challenge) == [],
         {:ok, _} <-
           OverallsProtocol.Readiness.response(
             Map.merge(binding, %{
               "version" => 1,
               "state" => "ready",
               "boot_id" => binding["placement_id"]
             })
           ) do
      {:ok,
       %{
         binding: binding,
         generation: generation,
         zone: zone,
         path: "/run/inception-proofs/verify.sock",
         uid: 0
       }}
    else
      _ -> :error
    end
  end

  def new(_, _), do: :error

  # @cc [owner:ghuntley,label:security] audi-proof-broker-freshness
  # The client MUST authenticate the connected Unix peer before sending exact
  # proof/boot/generation input. Connect, request and reply share a 500ms deadline.
  # A reply MUST remain live from request start, never gain time from receipt.
  # Missing, expired or refused evidence MUST fail without direct-DNS fallback.
  # Python and BEAM monotonic clock epochs MUST NOT be compared directly.
  @spec ready?(binary(), [binary()], map()) :: boolean()
  def ready?(hostname, proofs, source) do
    started = now()

    with true <- is_binary(hostname) and is_binary(source.zone),
         suffix = "." <> source.zone,
         true <- String.ends_with?(hostname, suffix),
         label = binary_part(hostname, 0, byte_size(hostname) - byte_size(suffix)),
         true <- OverallsProtocol.IngressName.valid_label?(label),
         {:ok, _} <-
           OverallsProtocol.InceptionObservation.validate(%{
             "request_id" => source.binding["placement_id"],
             "records" => [%{"label" => label, "proofs" => proofs, "ttl_ms" => 1}]
           }),
         body =
           JSON.encode!(%{
             version: 1,
             binding: source.binding,
             generation: source.generation,
             label: label,
             proofs: proofs
           }),
         true <- byte_size(body) <= 2048,
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, source.path},
             0,
             [
               :binary,
               active: false,
               packet: 4,
               packet_size: 256,
               send_timeout: 500,
               send_timeout_close: true
             ],
             500
           ) do
      try do
        uid = source.uid

        with {:ok,
              [
                {:raw, 1, 17,
                 <<_::native-signed-32, ^uid::native-unsigned-32, _::native-unsigned-32>>}
              ]} <-
               :inet.getopts(socket, [{:raw, 1, 17, 12}]),
             true <- now() < started + 500,
             :ok <- :inet.setopts(socket, send_timeout: remaining(started)),
             :ok <- :gen_tcp.send(socket, body),
             {:ok, reply} <- :gen_tcp.recv(socket, 0, remaining(started)),
             {:ok, %{"version" => 1, "ttl_ms" => ttl} = value} <- JSON.decode(reply),
             true <- map_size(value) == 2 and is_integer(ttl) and ttl in 1..5000 do
          now() < min(started + 500, started + ttl)
        else
          _ -> false
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(started), do: max(started + 500 - now(), 0)
end
