defmodule Marshall.Ingress.ACME.Propagation do
  @moduledoc "Direct bounded checks of configured Audi authoritative DNS replicas."
  import Bitwise

  @type failure_reason ::
          :invalid_request
          | :transport
          | :absent
          | :malformed_reply
          | :ttl_out_of_window
          | :value_mismatch
          | :local_defect

  # @cc [owner:ghuntley,label:security;protocol] audi-acme-proof-propagation
  # Acknowledgement readiness MUST require every configured replica to return
  # the exact live proof set authoritatively for the exact challenge owner.
  # Queries MUST use fixed operator-supplied IPv4/port pairs, bounded TCP framing
  # and timeouts, with no resolver fallback. Negative results MUST preserve a
  # closed cause class while omitting packets, names and proof values.
  @spec check(binary(), [binary()], [{:inet.ip4_address(), :inet.port_number()}]) ::
          :ok | {:error, failure_reason()}
  def check(hostname, proofs, peers) do
    if valid_owner?(hostname) and proofs?(proofs) and
         is_list(peers) and length(peers) in 1..8 and Enum.uniq(peers) == peers do
      owner = "_acme-challenge." <> hostname

      result =
        Enum.reduce_while(peers, {:ok, []}, fn peer, {:ok, deadlines} ->
          case query(peer, owner, proofs) do
            {:ok, deadline} -> {:cont, {:ok, [deadline | deadlines]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case result do
        {:ok, deadlines} ->
          now = System.monotonic_time(:millisecond)
          if Enum.all?(deadlines, &(&1 > now)), do: :ok, else: {:error, :ttl_out_of_window}

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :local_defect}
  catch
    _, _ -> {:error, :local_defect}
  end

  @spec ready?(binary(), [binary()], [{:inet.ip4_address(), :inet.port_number()}]) :: boolean()
  def ready?(hostname, proofs, peers), do: check(hostname, proofs, peers) == :ok

  @spec query(term(), binary(), [binary()]) ::
          {:ok, integer()} | {:error, failure_reason()}
  defp query({{a, b, c, d} = ip, port}, owner, proofs)
       when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255 and
              port in 1..65_535 do
    started = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(
           ip,
           port,
           [:inet, :binary, active: false, packet: 2, packet_size: 4096, send_timeout: 1000],
           1000
         ) do
      {:ok, socket} ->
        try do
          <<id::16>> = :crypto.strong_rand_bytes(2)

          packet =
            IO.iodata_to_binary([
              <<id::16, 0::16, 1::16, 0::48>>,
              encode_name(String.split(owner, ".")),
              <<16::16, 1::16>>
            ])

          with :ok <- :gen_tcp.send(socket, packet),
               {:ok, reply} <- :gen_tcp.recv(socket, 0, 1000) do
            decode_reply(reply, id, owner, proofs, started)
          else
            _ -> {:error, :transport}
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        {:error, :transport}
    end
  end

  defp query(_, _, _), do: {:error, :invalid_request}

  @spec decode_reply(binary(), non_neg_integer(), binary(), [binary()], integer()) ::
          {:ok, integer()} | {:error, failure_reason()}
  defp decode_reply(reply, id, owner, proofs, started) do
    with <<^id::16, flags::16, 1::16, count::16, 0::16, 0::16, _::binary>> <- reply,
         true <- (flags &&& 0xFE0F) == 0x8400,
         {:ok, message} <- :inet_dns.decode(reply),
         [question] <- :inet_dns.msg(message, :qdlist),
         true <-
           :inet_dns.dns_query(question, :domain) == String.to_charlist(owner) and
             :inet_dns.dns_query(question, :type) == :txt and
             :inet_dns.dns_query(question, :class) == :in,
         answers when is_list(answers) <- :inet_dns.msg(message, :anlist),
         true <- length(answers) == count do
      classify_answers(answers, owner, proofs, started)
    else
      _ -> {:error, :malformed_reply}
    end
  rescue
    _ -> {:error, :malformed_reply}
  end

  @spec classify_answers([tuple()], binary(), [binary()], integer()) ::
          {:ok, integer()} | {:error, failure_reason()}
  defp classify_answers([], _, _, _), do: {:error, :absent}

  defp classify_answers(answers, owner, proofs, started) do
    cond do
      length(answers) != length(proofs) or not Enum.all?(answers, &answer_header?(&1, owner)) ->
        {:error, :malformed_reply}

      not Enum.all?(answers, &(:inet_dns.rr(&1, :ttl) in 1..5)) ->
        {:error, :ttl_out_of_window}

      true ->
        values =
          Enum.map(answers, fn answer ->
            [part] = :inet_dns.rr(answer, :data)
            List.to_string(part)
          end)

        if Enum.sort(values) == Enum.sort(proofs),
          do: {:ok, started + Enum.min(Enum.map(answers, &(:inet_dns.rr(&1, :ttl) * 1000)))},
          else: {:error, :value_mismatch}
    end
  rescue
    _ -> {:error, :malformed_reply}
  end

  @spec answer_header?(tuple(), binary()) :: boolean()
  defp answer_header?(answer, owner),
    do:
      :inet_dns.rr(answer, :domain) == String.to_charlist(owner) and
        :inet_dns.rr(answer, :type) == :txt and :inet_dns.rr(answer, :class) == :in

  defp valid_owner?(hostname) when is_binary(hostname) and byte_size(hostname) <= 235 do
    parts = String.split(hostname, ".")

    length(parts) >= 2 and
      Enum.all?(parts, fn part ->
        byte_size(part) in 1..63 and
          Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, part)
      end)
  end

  defp valid_owner?(_), do: false

  defp proofs?(values) when is_list(values) and length(values) == 1 do
    [value] = values

    with true <- is_binary(value) and byte_size(value) == 43,
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(value, padding: false),
         do: Base.url_encode64(bytes, padding: false) == value,
         else: (_ -> false)
  end

  defp proofs?(_), do: false

  defp encode_name(parts),
    do: IO.iodata_to_binary(Enum.map(parts, &<<byte_size(&1), &1::binary>>) ++ [<<0>>])
end
