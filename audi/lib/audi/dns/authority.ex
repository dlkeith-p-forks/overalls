defmodule Audi.DNS.Authority do
  @moduledoc "Authoritative application-zone answers from Audi's local directory."
  import Bitwise
  alias Audi.DNS.{Directory, Wire}
  alias OverallsProtocol.IngressName

  @enforce_keys [:zone, :nameservers, :mailbox, :directory]
  defstruct [
    :zone,
    :nameservers,
    :mailbox,
    :directory,
    address_ttl: 20,
    negative_ttl: 5,
    ns_ttl: 3600
  ]

  @type t :: %__MODULE__{
          zone: [binary()],
          nameservers: [[binary()]],
          mailbox: [binary()],
          directory: GenServer.server(),
          address_ttl: pos_integer(),
          negative_ttl: pos_integer(),
          ns_ttl: pos_integer()
        }

  @spec answer(binary(), t(), :udp | :tcp) :: binary() | :drop
  def answer(packet, config, transport) do
    {response, _outcome} = answer_with_outcome(packet, config, transport)
    response
  end

  # @cc [owner:ghuntley,label:reliability;security] dns-candidate-outcome-classification
  # Only well-formed ordinary in-zone questions MAY enter the DNS candidate
  # denominator. Authoritative NOERROR and NXDOMAIN are successful completions;
  # stale-publication SERVFAIL is failure. Refusals, invalid requests, replies
  # to replies and truncated UDP responses MUST be excluded.
  @spec answer_with_outcome(binary(), t(), :udp | :tcp) ::
          {binary() | :drop, :success | :failure | :exclude}
  def answer_with_outcome(packet, config, transport) do
    case Wire.decode(packet) do
      {:ok, question} ->
        {code, answers, authority, authoritative} = resolve(question, config)
        response = Wire.reply(question, code, answers, authority, authoritative, transport)
        {response, classify(question, code, authoritative, response, config.zone)}

      {:error, :response} ->
        {:drop, :exclude}

      {:error, :malformed} ->
        {Wire.malformed(packet), :exclude}
    end
  end

  defp classify(question, code, authoritative, <<_id::16, flags::16, _::binary>>, zone) do
    ordinary? = eligible_question?(question, zone) and (flags &&& 0x0200) == 0

    cond do
      not ordinary? -> :exclude
      authoritative and code in [0, 3] -> :success
      code == 2 -> :failure
      true -> :exclude
    end
  end

  # @cc [owner:ghuntley,label:reliability;security] public-dns-pre-resolution-admission
  # Only decoded ordinary in-zone public questions MAY admit measurement before
  # directory lookup and answer generation. Malformed, out-of-zone, response,
  # transfer and unsupported opcode/EDNS questions MUST stay outside admission.
  @spec eligible?(binary(), t()) :: boolean()
  def eligible?(packet, config) do
    case Wire.decode(packet) do
      {:ok, question} -> eligible_question?(question, config.zone)
      _ -> false
    end
  end

  @spec eligible_question?(Wire.question(), [binary()]) :: boolean()
  defp eligible_question?(question, zone) do
    question.class == 1 and question.type not in [251, 252] and
      question.edns_version == 0 and (question.flags &&& 0x7800) == 0 and
      Enum.take(question.labels, -length(zone)) == zone
  end

  defp resolve(%{edns_version: version}, _) when version != 0, do: {16, [], [], false}
  defp resolve(%{flags: flags}, _) when (flags &&& 0x7800) != 0, do: {4, [], [], false}
  defp resolve(%{class: class}, _) when class != 1, do: {5, [], [], false}
  defp resolve(%{type: type}, _) when type in [251, 252], do: {5, [], [], false}

  defp resolve(question, config) do
    if Enum.take(question.labels, -length(config.zone)) == config.zone do
      local_answer(question, config)
    else
      {5, [], [], false}
    end
  end

  defp local_answer(question, config) do
    case Directory.lookup(config.directory, publication_name(question.labels, config.zone)) do
      :stale ->
        {2, [], [], false}

      {:ok, revision, entry} ->
        soa = soa(config, revision)

        cond do
          question.labels == config.zone ->
            apex(question, config, soa)

          is_nil(entry) ->
            {3, [], [soa], true}

          entry == %{empty: true} ->
            code =
              if Enum.join(question.labels, ".") == publication_name(question.labels, config.zone),
                do: 0,
                else: 3

            {code, [], [soa], true}

          Map.has_key?(entry, :challenges) ->
            challenge(question, config, entry, soa)

          true ->
            addresses(question, config, entry, soa)
        end
    end
  end

  defp challenge(question, config, entry, soa) do
    case Enum.drop(question.labels, -length(config.zone)) do
      ["_acme-challenge" | relative] ->
        if (relative == [] or
              OverallsProtocol.InceptionName.publication?(Enum.join(relative, ".")) or
              OverallsProtocol.InceptionName.wildcard_proof_owner?(Enum.join(relative, "."))) and
             Audi.DNS.Challenge.live?(entry) do
          ttl = min(5, max(0, div(entry.expires_at - System.monotonic_time(:millisecond), 1000)))

          case question.type do
            16 ->
              records =
                Enum.map(entry.challenges, &{question.labels, 16, ttl, <<43, &1::binary>>})

              {0, records, [], true}

            255 ->
              minimal_any(question.labels, %{config | address_ttl: ttl})

            _ ->
              {0, [], [soa], true}
          end
        else
          {3, [], [soa], true}
        end

      _ ->
        {3, [], [soa], true}
    end
  end

  # @cc [owner:ghuntley,label:protocol;security] dns-alternate-publication-binding
  # Only canonical application/editor identities or webview hashes may inherit
  # their explicit neutral publication address.
  # Answers MUST retain the queried owner name and
  # share the base publication's revision, removal and freshness boundary.
  # This MUST NOT become a general wildcard or an application access grant.
  defp publication_name(labels, zone) do
    relative = Enum.drop(labels, -length(zone))

    case relative do
      [application] ->
        cond do
          String.starts_with?(application, "e-") ->
            case OverallsProtocol.EditorName.parse(application) do
              {:ok, %{vm_id: vm}} ->
                Enum.join(["editor-" <> String.replace(vm, "-", "") | zone], ".")

              _ ->
                Enum.join(labels, ".")
            end

          OverallsProtocol.EditorName.webview_label?(application) ->
            Enum.join(["webview" | zone], ".")

          true ->
            case IngressName.application_label(application) do
              {:ok, vm, port} when port > 0 -> Enum.join([vm | zone], ".")
              _ -> Enum.join(labels, ".")
            end
        end

      _ ->
        Enum.join(labels, ".")
    end
  end

  defp apex(%{type: 6}, _, soa), do: {0, [soa], [], true}

  defp apex(%{type: 2}, config, _) do
    records = Enum.map(config.nameservers, &{config.zone, 2, config.ns_ttl, Wire.encode_name(&1)})
    {0, records, [], true}
  end

  defp apex(%{type: 255, labels: labels}, config, _), do: minimal_any(labels, config)
  defp apex(_, _, soa), do: {0, [], [soa], true}

  # @cc [owner:ghuntley,label:security] dns-address-cache-deadline
  # Address and minimal ANY TTLs MUST NOT exceed a publication's remaining
  # lifetime.
  defp addresses(%{type: 255, labels: labels}, config, entry, _),
    do: minimal_any(labels, %{config | address_ttl: address_ttl(config, entry)})

  defp addresses(question, config, entry, soa) do
    records =
      for address <- entry.addresses,
          {type, data} <- [address_data(address)],
          type == question.type,
          do: {question.labels, type, address_ttl(config, entry), data}

    {0, records, if(records == [], do: [soa], else: []), true}
  end

  defp address_ttl(config, %{expires_at: expiry}),
    do: min(config.address_ttl, max(0, div(expiry - System.monotonic_time(:millisecond), 1000)))

  defp minimal_any(labels, config),
    do: {0, [{labels, 13, config.address_ttl, <<7, "RFC8482", 0>>}], [], true}

  defp address_data({a, b, c, d}), do: {1, <<a, b, c, d>>}

  defp address_data(_), do: nil

  defp soa(config, revision) do
    data =
      Wire.encode_name(hd(config.nameservers)) <>
        Wire.encode_name(config.mailbox) <>
        <<rem(revision, 4_294_967_296)::32, 20::32, 5::32, 60::32, config.negative_ttl::32>>

    {config.zone, 6, config.negative_ttl, data}
  end
end
