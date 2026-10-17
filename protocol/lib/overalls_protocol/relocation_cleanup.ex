defmodule OverallsProtocol.RelocationCleanup do
  @moduledoc "Source retirement commands and physical deletion receipts."
  alias OverallsProtocol.Relocation
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          generation: pos_integer(),
          expires_at: pos_integer()
        }
  @type result :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          generation: pos_integer()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;recovery] cleanup-exact-source-retirement
  # Commands MUST bind a final descriptor, its relocation ID and stopped source
  # generation under a live lease. Success receipts assert fenced export and
  # physical source deletion, never destination deletion or logical VM archival.
  # The host MUST retain tombstones and refuse mismatched authority on retries.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "descriptor" => wire,
          "generation" => generation,
          "expires_at" => expires
        } = value
      )
      when map_size(value) == 4 do
    with true <-
           OverallsProtocol.uuid?(id) and positive?(generation) and generation < @maximum and
             positive?(expires),
         {:ok, descriptor} <- final(wire),
         true <- id == descriptor.relocation_id,
         do:
           {:ok,
            %{
              id: id,
              descriptor: descriptor,
              generation: generation,
              expires_at: expires
            }},
         else: (_ -> {:error, :invalid_message})
  end

  def command(_), do: {:error, :invalid_message}
  @spec result(term()) :: {:ok, result()} | failure()
  def result(%{"id" => id, "descriptor" => wire, "generation" => generation} = value)
      when map_size(value) == 3 do
    with true <-
           OverallsProtocol.uuid?(id) and positive?(generation) and generation < @maximum,
         {:ok, descriptor} <- final(wire),
         true <- id == descriptor.relocation_id,
         do: {:ok, %{id: id, descriptor: descriptor, generation: generation}},
         else: (_ -> {:error, :invalid_message})
  end

  def result(_), do: {:error, :invalid_message}
  @spec exchange(term()) :: {:ok, exchange()} | failure()
  def exchange(
        %{"version" => 4, "session_id" => id, "epoch" => epoch, "results" => values} = value
      )
      when map_size(value) == 4 do
    with true <- OverallsProtocol.uuid?(id) and positive?(epoch),
         {:ok, results} <- collection(values, &result/1),
         do: {:ok, %{session_id: id, epoch: epoch, results: results}},
         else: (_ -> {:error, :invalid_message})
  end

  def exchange(%{"version" => version}) when version != 4, do: {:error, :unsupported_version}
  def exchange(_), do: {:error, :invalid_message}
  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1)
  @spec encode_command(command()) :: map()
  def encode_command(command),
    do: %{
      "id" => command.id,
      "descriptor" => Relocation.encode_descriptor(command.descriptor),
      "generation" => command.generation,
      "expires_at" => command.expires_at
    }

  @spec encode_result(result()) :: map()
  def encode_result(result),
    do: %{
      "id" => result.id,
      "descriptor" => Relocation.encode_descriptor(result.descriptor),
      "generation" => result.generation
    }

  defp final(wire) do
    with {:ok, descriptor} <- Relocation.descriptor(wire),
         do: {:ok, descriptor},
         else: (_ -> {:error, :invalid_message})
  end

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
  defp positive?(value), do: is_integer(value) and value in 1..@maximum
end
