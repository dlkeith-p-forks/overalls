defmodule OverallsProtocol.RelocationKeys do
  @moduledoc "Closed v4 destination key preparation messages; never disk or execution authority."
  alias OverallsProtocol.TransferSSH
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          host_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          source_host_id: String.t(),
          source_endpoint: TransferSSH.endpoint()
        }
  @type result :: %{
          id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          public_key: String.t()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] relocation-key-preparation-only
  # Commands and results MUST bind one relocation and destination placement/epoch.
  # Commands MUST also bind the destination host and distinct
  # enrolled source host/pin. Only public Ed25519 keys may return. Paths, private
  # material, extra fields and unsupported versions MUST fail closed. Acceptance
  # grants neither a source permit nor permission to import or execute a disk.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "host_id" => host,
          "placement_id" => placement,
          "execution_epoch" => epoch,
          "source_host_id" => source,
          "source_endpoint" => endpoint
        } = value
      )
      when map_size(value) == 6 do
    with true <- Enum.all?([id, host, placement, source], &OverallsProtocol.uuid?/1),
         true <- host != source,
         true <- is_integer(epoch) and epoch in 2..@maximum,
         {:ok, endpoint} <- TransferSSH.endpoint(endpoint) do
      {:ok,
       %{
         id: id,
         host_id: host,
         placement_id: placement,
         execution_epoch: epoch,
         source_host_id: source,
         source_endpoint: endpoint
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
          "execution_epoch" => epoch,
          "public_key" => key
        } = value
      )
      when map_size(value) == 4 do
    if OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(placement) and
         is_integer(epoch) and epoch in 2..@maximum and TransferSSH.public_key?(key),
       do: {:ok, %{id: id, placement_id: placement, execution_epoch: epoch, public_key: key}},
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

  # @cc [owner:ghuntley,label:protocol] relocation-key-batch-bound
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
