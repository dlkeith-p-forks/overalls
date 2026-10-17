defmodule OverallsProtocol.RelocationReadiness do
  @moduledoc "Activation-bound guest readiness commands and boot receipts."
  alias OverallsProtocol.Relocation
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          generation: pos_integer(),
          expires_at: pos_integer(),
          timeout_ms: pos_integer()
        }
  @type result :: %{
          id: String.t(),
          descriptor: Relocation.descriptor(),
          generation: pos_integer(),
          boot_id: String.t()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] readiness-wire-binds-activation
  # Commands MUST bind a final relocation descriptor, activation operation ID and
  # generation, bounded probe duration and control expiry. Results bind the same
  # identity to a guest boot UUID. No socket paths or boot challenges cross this
  # boundary; the host must use its own persisted challenge and current VMM.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "descriptor" => wire,
          "generation" => generation,
          "expires_at" => expires,
          "timeout_ms" => timeout
        } = value
      )
      when map_size(value) == 5 do
    with true <- OverallsProtocol.uuid?(id) and positive?(generation) and positive?(expires),
         true <- is_integer(timeout) and timeout in 1..600_000,
         {:ok, descriptor} <- final(wire),
         do:
           {:ok,
            %{
              id: id,
              descriptor: descriptor,
              generation: generation,
              expires_at: expires,
              timeout_ms: timeout
            }},
         else: (_ -> {:error, :invalid_message})
  end

  def command(_), do: {:error, :invalid_message}
  @spec result(term()) :: {:ok, result()} | failure()
  def result(
        %{"id" => id, "descriptor" => wire, "generation" => generation, "boot_id" => boot} = value
      )
      when map_size(value) == 4 do
    with true <-
           OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(boot) and positive?(generation),
         {:ok, descriptor} <- final(wire),
         do: {:ok, %{id: id, descriptor: descriptor, generation: generation, boot_id: boot}},
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
      "expires_at" => command.expires_at,
      "timeout_ms" => command.timeout_ms
    }

  @spec encode_result(result()) :: map()
  def encode_result(result),
    do: %{
      "id" => result.id,
      "descriptor" => Relocation.encode_descriptor(result.descriptor),
      "generation" => result.generation,
      "boot_id" => result.boot_id
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
