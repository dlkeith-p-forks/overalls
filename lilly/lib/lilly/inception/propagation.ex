defmodule Lilly.Inception.Propagation do
  @moduledoc "Bounded parent-side authoritative DNS observations for one child publication."
  import Bitwise
  alias OverallsProtocol.{InceptionExchange, InceptionName, InceptionPublic}

  # @cc [owner:ghuntley,label:security;protocol] inception-proof-fixed-destinations
  # Observations MUST query only the authenticated operator's distinct IPv4 DNS
  # endpoints, for names derived from this environment's validated publication.
  # Every configured replica MUST return the exact proof set authoritatively.
  # No child value may select an IP, port or arbitrary name. Errors MUST disclose
  # neither packets nor names. Results are evidence, not publication authority.

  # @cc [owner:ghuntley,label:security;capacity] inception-proof-query-budget
  # One round MUST select at most sixteen owners, run at most four owner checks
  # concurrently, and share a 1200ms deadline capped by the original publication
  # lease. Each owner checks replicas serially. Returned TTLs MUST be remaining
  # lifetimes capped by both the source publication and observed DNS TTLs.
  @spec observe(map(), map(), integer(), non_neg_integer()) :: map()
  def observe(namespace, publication, publication_deadline, cursor \\ 0) do
    with {:ok, _} <- InceptionExchange.encode(publication),
         {:ok, public} when is_map(public) <- InceptionPublic.validate(namespace[:public]),
         {:ok, origins} <- InceptionName.origins(namespace.label, namespace.zone),
         true <- is_integer(publication_deadline) and publication_deadline > now(),
         true <- is_integer(cursor) and cursor >= 0 do
      until = min(publication_deadline, now() + 1200)
      records = Enum.filter(publication["records"], &(&1["proofs"] != []))
      offset = if records == [], do: 0, else: rem(cursor, length(records))
      selected = Enum.take(Enum.drop(records, offset) ++ Enum.take(records, offset), 16)

      observed =
        selected
        |> Task.async_stream(
          fn record ->
            Process.flag(:sensitive, true)

            owner =
              "_acme-challenge." <>
                case record["label"] do
                  "control" -> origins.control
                  "" -> origins.apps
                  label -> label <> "." <> origins.apps
                end

            deadlines =
              Enum.map(public["nameservers"], &query(&1, owner, record["proofs"], until))

            if Enum.all?(deadlines, &is_integer/1) do
              %{
                label: record["label"],
                proofs: record["proofs"],
                expires: Enum.min([publication_deadline | deadlines])
              }
            end
          end,
          max_concurrency: 4,
          ordered: false,
          timeout: 1400,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, %{expires: _} = record} -> [record]
          _ -> []
        end)

      current = now()

      records =
        Enum.flat_map(observed, fn record ->
          ttl = min(record.expires - current, 5000)

          if ttl > 0,
            do: [%{"label" => record.label, "proofs" => record.proofs, "ttl_ms" => ttl}],
            else: []
        end)

      %{"request_id" => publication["request_id"], "records" => records}
    else
      _ -> %{"request_id" => publication["request_id"], "records" => []}
    end
  rescue
    _ -> %{"request_id" => nil, "records" => []}
  catch
    _, _ -> %{"request_id" => nil, "records" => []}
  end

  defp query(peer, owner, proofs, until) do
    with true <- now() < until,
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(peer["address"])),
         {:ok, socket} <-
           :gen_tcp.connect(
             ip,
             peer["port"],
             [
               :inet,
               :binary,
               active: false,
               packet: 2,
               packet_size: 4096,
               send_timeout: remaining(until),
               send_timeout_close: true
             ],
             remaining(until)
           ) do
      try do
        started = now()
        <<id::16>> = :crypto.strong_rand_bytes(2)

        question =
          IO.iodata_to_binary([<<id::16, 0::16, 1::16, 0::48>>, name(owner), <<16::16, 1::16>>])

        with true <- started < until,
             :ok <- :gen_tcp.send(socket, question),
             {:ok, reply} <- :gen_tcp.recv(socket, 0, remaining(until)),
             true <- now() < until,
             <<^id::16, flags::16, 1::16, count::16, 0::16, 0::16, _::binary>> <- reply,
             true <- (flags &&& 0xFE0F) == 0x8400 and count == length(proofs),
             {:ok, message} <- :inet_dns.decode(reply),
             [question] <- :inet_dns.msg(message, :qdlist),
             true <-
               :inet_dns.dns_query(question, :domain) == String.to_charlist(owner) and
                 :inet_dns.dns_query(question, :type) == :txt and
                 :inet_dns.dns_query(question, :class) == :in,
             answers = :inet_dns.msg(message, :anlist),
             true <- Enum.all?(answers, &answer?(&1, owner)),
             values =
               Enum.map(answers, fn answer ->
                 [part] = :inet_dns.rr(answer, :data)
                 List.to_string(part)
               end),
             true <- Enum.sort(values) == Enum.sort(proofs) do
          started + Enum.min(Enum.map(answers, &(:inet_dns.rr(&1, :ttl) * 1000)))
        else
          _ -> nil
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp answer?(answer, owner),
    do:
      :inet_dns.rr(answer, :domain) == String.to_charlist(owner) and
        :inet_dns.rr(answer, :type) == :txt and :inet_dns.rr(answer, :class) == :in and
        :inet_dns.rr(answer, :ttl) in 1..5

  defp name(host), do: [Enum.map(String.split(host, "."), &<<byte_size(&1), &1::binary>>), <<0>>]
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(until), do: max(until - now(), 0)
end
