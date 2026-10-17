defmodule OverallsProtocol.RelocationImport do
  @moduledoc "Leased final-disk adoption, distinct from staging and execution authority."
  alias OverallsProtocol.{Relocation, RelocationReceive, Storage}

  @type command :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          dataset_guid: String.t(),
          source_endpoint: map(),
          expires_at: pos_integer()
        }
  @type result :: RelocationReceive.result()
  @type exchange :: RelocationReceive.exchange()
  @type failure :: RelocationReceive.failure()

  # @cc [owner:ghuntley,label:security;protocol] import-command-final-local-guid
  # Adoption commands MUST bind the received full-stream descriptor and canonical
  # destination-local GUID under a bounded control lease. Results are adoption
  # facts only, never execution authority, readiness or source deletion.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(%{"dataset_guid" => guid} = wire) when map_size(wire) == 5 do
    with true <- Storage.guid?(guid),
         {:ok, command} <- RelocationReceive.command(Map.delete(wire, "dataset_guid")),
         do: {:ok, Map.put(command, :dataset_guid, guid)},
         else: (_ -> {:error, :invalid_message})
  end

  def command(_), do: {:error, :invalid_message}

  @spec result(term()) :: {:ok, result()} | failure()
  defdelegate result(wire), to: RelocationReceive

  @spec exchange(term()) :: {:ok, exchange()} | failure()
  defdelegate exchange(wire), to: RelocationReceive

  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case command(value) do
        {:ok, decoded} ->
          if Enum.any?(acc, &(&1.id == decoded.id)),
            do: {:halt, {:error, :invalid_message}},
            else: {:cont, {:ok, [decoded | acc]}}

        _ ->
          {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, commands} -> {:ok, Enum.reverse(commands)}
      error -> error
    end
  end

  def commands(_), do: {:error, :invalid_message}
  @spec encode_command(command()) :: map()
  def encode_command(command),
    do:
      Map.put(
        RelocationReceive.encode_command(Map.delete(command, :dataset_guid)),
        "dataset_guid",
        command.dataset_guid
      )

  @spec encode_result(result()) :: map()
  defdelegate encode_result(result), to: RelocationReceive
end
