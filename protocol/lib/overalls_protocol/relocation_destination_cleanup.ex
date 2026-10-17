defmodule OverallsProtocol.RelocationDestinationCleanup do
  @moduledoc "Closed cancelled-destination reclamation intent and receipts."
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          intent: OverallsProtocol.Relocation.intent(),
          expires_at: pos_integer()
        }
  @type result :: %{
          id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] destination-cleanup-intent-without-lineage
  # Commands MUST bind the relocation ID to a closed immutable placement intent
  # and expiry, without inventing stream GUIDs. Consumers MUST independently
  # authorize cancellation, fence execution/transfers and prove local reclamation.
  # Receipts identify only the reclaimed destination placement and epoch.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(%{"id" => id, "intent" => wire, "expires_at" => expires} = value)
      when map_size(value) == 3 do
    with {:ok, intent} <- OverallsProtocol.Relocation.intent(wire),
         true <- id == intent.relocation_id,
         true <- is_integer(expires) and expires in 1..@maximum,
         do: {:ok, %{id: id, intent: intent, expires_at: expires}},
         else: (_ -> {:error, :invalid_message})
  end

  def command(_), do: {:error, :invalid_message}

  @spec result(term()) :: {:ok, result()} | failure()
  def result(
        %{
          "id" => id,
          "placement_id" => placement,
          "execution_epoch" => epoch
        } = value
      )
      when map_size(value) == 3 do
    if OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(placement) and
         is_integer(epoch) and epoch in 2..@maximum,
       do: {:ok, %{id: id, placement_id: placement, execution_epoch: epoch}},
       else: {:error, :invalid_message}
  end

  def result(_), do: {:error, :invalid_message}

  @spec exchange(term()) :: {:ok, exchange()} | failure()
  def exchange(
        %{"version" => 4, "session_id" => id, "epoch" => epoch, "results" => results} = value
      )
      when map_size(value) == 4 do
    with true <- OverallsProtocol.uuid?(id) and is_integer(epoch) and epoch in 1..@maximum,
         {:ok, results} <- results(results),
         do: {:ok, %{session_id: id, epoch: epoch, results: results}},
         else: (_ -> {:error, :invalid_message})
  end

  def exchange(%{"version" => version}) when version != 4, do: {:error, :unsupported_version}
  def exchange(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:protocol] destination-cleanup-batch-bound
  # Each batch MUST contain at most sixteen distinct relocation IDs. A malformed
  # or duplicate item MUST reject the entire batch, not partially accept it.
  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1)
  @spec results(term()) :: {:ok, [result()]} | failure()
  def results(values), do: collection(values, &result/1)

  @spec encode(command() | result()) :: map()
  def encode(%{intent: intent} = value),
    do: %{
      "id" => value.id,
      "intent" => OverallsProtocol.Relocation.encode_intent(intent),
      "expires_at" => value.expires_at
    }

  def encode(value), do: Map.new(value, fn {key, item} -> {Atom.to_string(key), item} end)

  defp collection(values, decoder) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decoder.(value) do
        {:ok, decoded} ->
          if Enum.any?(acc, &(&1.id == decoded.id)),
            do: {:halt, {:error, :invalid_message}},
            else: {:cont, {:ok, [decoded | acc]}}

        _ ->
          {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp collection(_, _), do: {:error, :invalid_message}
end
