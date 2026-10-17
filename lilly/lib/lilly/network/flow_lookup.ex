defmodule Lilly.Network.FlowLookup do
  @moduledoc "Bounded exact-tuple kernel label lookup inside the owned Lilly namespace."
  alias Lilly.Host.Command
  alias Lilly.Network.Config
  @type endpoint :: {{byte(), byte(), byte(), byte()}, 1..65_535}
  @type flow :: %{source: endpoint(), destination: endpoint()}

  # @cc [owner:ghuntley,label:security] flow-lookup-no-address-only-fallback
  # Lookup MUST use both complete kernel endpoints and accept only the helper's
  # fixed label response. Any validation, namespace, utility or decoding failure
  # MUST remain unresolved; it MUST NOT fall back to an address allocation lookup.
  @spec label(Config.t(), flow()) :: {:ok, String.t()} | {:error, :unresolved}
  def label(%Config{} = config, flow) do
    with {:ok, arguments} <- arguments(flow),
         {:ok, response} <- Command.in_namespace(config.namespace, :flow_label, arguments),
         do: decode(response),
         else: (_ -> {:error, :unresolved})
  end

  @spec arguments(term()) :: {:ok, [String.t()]} | {:error, :unresolved}
  def arguments(%{source: source, destination: destination} = flow) when map_size(flow) == 2 do
    with {:ok, left} <- endpoint(source),
         {:ok, right} <- endpoint(destination),
         do: {:ok, left ++ right}
  end

  def arguments(_), do: {:error, :unresolved}

  @spec decode(term()) :: {:ok, String.t()} | {:error, :unresolved}
  def decode(<<label::binary-size(32), "\n">>) do
    if Regex.match?(~r/\A[89a-f][0-9a-f]{31}\z/, label),
      do: {:ok, label},
      else: {:error, :unresolved}
  end

  def decode(_), do: {:error, :unresolved}

  defp endpoint({{a, b, c, d} = address, port})
       when is_integer(a) and a in 0..255 and is_integer(b) and b in 0..255 and
              is_integer(c) and c in 0..255 and is_integer(d) and d in 0..255 and
              is_integer(port) and port in 1..65_535,
       do: {:ok, [address |> :inet.ntoa() |> List.to_string(), Integer.to_string(port)]}

  defp endpoint(_), do: {:error, :unresolved}
end
