defmodule OverallsProtocol.RelocationSource do
  @moduledoc "Closed source snapshot/permit requests and correlated native descriptor results."
  alias OverallsProtocol.{Relocation, Storage, TransferSSH}
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          intent: Relocation.intent(),
          generation: pos_integer(),
          public_key: String.t(),
          revision: pos_integer(),
          expires_at: pos_integer(),
          to_guid: String.t() | nil
        }
  @type result :: %{id: String.t(), descriptor: Relocation.descriptor()}
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:protocol;security] source-request-closed-authority
  # Requests MUST bind immutable relocation endpoints/epochs/workload, source
  # generation, peer public key, revision and absolute expiry. Only first native
  # snapshot creation may omit its to GUID. Every request asks for the one full
  # stream of a physically stopped source (ADR-0155); there is no stream kind or
  # parent GUID. No local path, private key or executable argv is admissible.
  # Consumers MUST enforce current authority, physical stop, and a locally
  # bounded remaining lease; parsing establishes none of these.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "intent" => intent,
          "generation" => generation,
          "public_key" => public,
          "revision" => revision,
          "expires_at" => expires,
          "to_guid" => to
        } = value
      )
      when map_size(value) == 7 do
    with true <-
           OverallsProtocol.uuid?(id) and positive?(generation) and positive?(revision) and
             positive?(expires),
         {:ok, intent} <- Relocation.intent(intent),
         true <- TransferSSH.public_key?(public),
         true <- is_nil(to) or Storage.guid?(to) do
      {:ok,
       %{
         id: id,
         intent: intent,
         generation: generation,
         public_key: public,
         revision: revision,
         expires_at: expires,
         to_guid: to
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def command(_), do: {:error, :invalid_message}

  @spec result(term()) :: {:ok, result()} | failure()
  def result(%{"id" => id, "descriptor" => descriptor} = value) when map_size(value) == 2 do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, descriptor} <- Relocation.descriptor(descriptor),
         do: {:ok, %{id: id, descriptor: descriptor}},
         else: (_ -> {:error, :invalid_message})
  end

  def result(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:protocol;recovery] source-result-exact-request
  # A result MUST match its immutable request ID, all intent fields and any
  # previously bound to GUID. A matching result is only a source observation;
  # it MUST NOT prove destination receipt or live lease time.
  @spec matches?(command(), result()) :: boolean()
  def matches?(command, result) do
    descriptor = result.descriptor

    result.id == command.id and Map.delete(descriptor, :stream) == command.intent and
      (command.to_guid == nil or command.to_guid == descriptor.stream.to_guid)
  end

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
  def encode_command(command) do
    command
    |> Map.delete(:intent)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("intent", Relocation.encode_intent(command.intent))
  end

  @spec encode_result(result()) :: map()
  def encode_result(result),
    do: %{"id" => result.id, "descriptor" => Relocation.encode_descriptor(result.descriptor)}

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
