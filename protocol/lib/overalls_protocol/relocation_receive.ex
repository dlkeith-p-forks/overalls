defmodule OverallsProtocol.RelocationReceive do
  @moduledoc "Closed destination receive commands and locally owned dataset receipts."
  alias OverallsProtocol.{Relocation, Storage, TransferSSH}
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          source_endpoint: map(),
          expires_at: pos_integer()
        }
  @type result :: %{id: String.t(), descriptor: Relocation.descriptor(), dataset_guid: String.t()}
  @type exchange :: %{
          session_id: String.t(),
          epoch: pos_integer(),
          results: [result()]
        }
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] receive-wire-import-only
  # Commands MUST bind a source-confirmed descriptor, enrolled source pin and
  # absolute permit expiry. Results MUST bind the same request/descriptor and a
  # canonical destination-local filesystem GUID. No paths, private keys or argv
  # may cross this boundary. Neither parsing nor receipt grants execution or
  # proves a still-live source lease; consumers must recheck durable authority.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "descriptor" => value,
          "source_endpoint" => endpoint,
          "expires_at" => expires
        } = wire
      )
      when map_size(wire) == 4 do
    with true <- OverallsProtocol.uuid?(id) and positive?(expires),
         {:ok, descriptor} <- Relocation.descriptor(value),
         {:ok, endpoint} <- TransferSSH.endpoint(endpoint),
         do:
           {:ok,
            %{id: id, descriptor: descriptor, source_endpoint: endpoint, expires_at: expires}},
         else: (_ -> {:error, :invalid_message})
  end

  def command(_), do: {:error, :invalid_message}

  @spec result(term()) :: {:ok, result()} | failure()
  def result(%{"id" => id, "descriptor" => value, "dataset_guid" => guid} = wire)
      when map_size(wire) == 3 do
    with true <- OverallsProtocol.uuid?(id) and Storage.guid?(guid),
         {:ok, descriptor} <- Relocation.descriptor(value),
         do: {:ok, %{id: id, descriptor: descriptor, dataset_guid: guid}},
         else: (_ -> {:error, :invalid_message})
  end

  def result(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:protocol] receive-exchange-authority-only
  # The exchange MUST carry only current session fences and physical receipts.
  # Diagnostic progress and every other extra field MUST reject the exchange.
  @spec exchange(term()) :: {:ok, exchange()} | failure()
  def exchange(
        %{"version" => 4, "session_id" => id, "epoch" => epoch, "results" => values} = value
      )
      when map_size(value) == 4 do
    with true <- OverallsProtocol.uuid?(id) and positive?(epoch),
         {:ok, results} <- results(values),
         do: {:ok, %{session_id: id, epoch: epoch, results: results}},
         else: (_ -> {:error, :invalid_message})
  end

  def exchange(%{"version" => version}) when version != 4, do: {:error, :unsupported_version}
  def exchange(_), do: {:error, :invalid_message}

  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1)
  @spec results(term()) :: {:ok, [result()]} | failure()
  def results(values), do: collection(values, &result/1)
  @spec encode_command(command()) :: map()
  def encode_command(command),
    do: %{
      "id" => command.id,
      "descriptor" => Relocation.encode_descriptor(command.descriptor),
      "source_endpoint" => command.source_endpoint,
      "expires_at" => command.expires_at
    }

  @spec encode_result(result()) :: map()
  def encode_result(result),
    do: %{
      "id" => result.id,
      "descriptor" => Relocation.encode_descriptor(result.descriptor),
      "dataset_guid" => result.dataset_guid
    }

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
