defmodule Audi.Private.DNS do
  @moduledoc "Closed, authoritative `.internal` service namespace; never recursive."
  import Bitwise
  alias Audi.DNS.Wire
  @integration_zone ~w(integration internal)
  @label_regex ~r/\A[a-z][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z]\z/

  # @cc [owner:ghuntley,label:security] internal-dns-closed-namespace
  # Only llm.internal and exactly one label before the fixed integration zone
  # have addresses. Unknown internal names MUST return authoritative NXDOMAIN,
  # other zones MUST be refused, and AAAA MUST return NODATA. Answers MUST NOT
  # imply request authorization or service readiness.
  @spec answer(binary(), term(), :udp | :tcp) :: binary() | :drop
  def answer(packet, _config, transport) do
    case Wire.decode(packet) do
      {:ok, question} ->
        {code, answers, authority, authoritative} = resolve(question)
        Wire.reply(question, code, answers, authority, authoritative, transport)

      {:error, :response} ->
        :drop

      {:error, :malformed} ->
        Wire.malformed(packet)
    end
  end

  defp resolve(%{edns_version: version}) when version != 0, do: {16, [], [], false}
  defp resolve(%{flags: flags}) when (flags &&& 0x7800) != 0, do: {4, [], [], false}
  defp resolve(%{class: class}) when class != 1, do: {5, [], [], false}
  defp resolve(%{type: type}) when type in [251, 252], do: {5, [], [], false}

  defp resolve(%{labels: ["llm", "internal"], type: 1}),
    do: {0, [{["llm", "internal"], 1, 20, <<169, 254, 254, 1>>}], [], true}

  defp resolve(%{labels: ["reflection", "internal"], type: 1}),
    do: {0, [{["reflection", "internal"], 1, 20, <<169, 254, 254, 1>>}], [], true}

  defp resolve(%{labels: [label | zone], type: 1})
       when zone == @integration_zone and label != "integration",
       do: integration_address(label)

  defp resolve(%{labels: @integration_zone, type: 6}), do: {0, [integration_soa()], [], true}

  defp resolve(%{labels: ["internal"], type: 6}), do: {0, [soa()], [], true}

  defp resolve(%{labels: labels})
       when labels in [
              ["llm", "internal"],
              ["reflection", "internal"],
              ["internal"],
              @integration_zone
            ],
       do: {0, [], [soa()], true}

  defp resolve(%{labels: labels}) do
    if List.last(labels) == "internal", do: {3, [], [soa()], true}, else: {5, [], [], false}
  end

  defp integration_address(label) when is_binary(label) do
    if Regex.match?(@label_regex, label),
      do: {0, [{[label | @integration_zone], 1, 20, <<169, 254, 254, 1>>}], [], true},
      else: {3, [], [soa()], true}
  end

  defp soa do
    data =
      Wire.encode_name(["llm", "internal"]) <>
        Wire.encode_name(["hostmaster", "internal"]) <>
        <<1::32, 20::32, 5::32, 60::32, 5::32>>

    {["internal"], 6, 5, data}
  end

  defp integration_soa do
    data =
      Wire.encode_name(["llm", "internal"]) <>
        Wire.encode_name(["hostmaster", "internal"]) <>
        <<1::32, 20::32, 5::32, 60::32, 5::32>>

    {@integration_zone, 6, 5, data}
  end
end
