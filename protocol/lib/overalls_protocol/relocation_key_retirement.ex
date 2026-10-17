defmodule OverallsProtocol.RelocationKeyRetirement do
  @moduledoc "Closed destination credential retirement commands and receipts."
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          host_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          expires_at: pos_integer()
        }
  @type result :: %{
          id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] retirement-identity-without-key-material
  # Commands MUST bind host, relocation, destination placement/epoch and expiry.
  # Receipts contain only that relocation/placement/epoch identity. No paths or
  # key material may cross this boundary; retirement cannot grant disk authority.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "host_id" => host,
          "placement_id" => placement,
          "execution_epoch" => epoch,
          "expires_at" => expires
        } = value
      )
      when map_size(value) == 5 do
    with true <- Enum.all?([id, host, placement], &OverallsProtocol.uuid?/1),
         true <- is_integer(epoch) and epoch in 2..@maximum,
         true <- is_integer(expires) and expires in 1..@maximum do
      {:ok,
       %{
         id: id,
         host_id: host,
         placement_id: placement,
         execution_epoch: epoch,
         expires_at: expires
       }}
    else
      _ -> {:error, :invalid_message}
    end
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

  # @cc [owner:ghuntley,label:protocol] retirement-key-batch-bound
  # Each batch MUST contain at most sixteen distinct relocation IDs. A malformed
  # or duplicate item MUST reject the entire batch, not partially accept it.
  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1)
  @spec results(term()) :: {:ok, [result()]} | failure()
  def results(values), do: collection(values, &result/1)

  @spec encode(command() | result()) :: map()
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
