defmodule OverallsProtocol.RelocationProbe do
  @moduledoc "Closed source lease and destination connectivity commands; no stop authority."
  alias OverallsProtocol.{Relocation, TransferSSH}
  @maximum 9_223_372_036_854_775_807
  @type command :: %{
          id: String.t(),
          intent: Relocation.intent(),
          generation: pos_integer(),
          phase: :grant | :probe,
          public_key: String.t(),
          challenge: String.t(),
          revision: pos_integer(),
          expires_at: pos_integer(),
          source_endpoint: map() | nil
        }
  @type result :: %{
          id: String.t(),
          phase: :grant | :probe,
          challenge: String.t(),
          revision: pos_integer(),
          expires_at: pos_integer()
        }
  @type exchange :: %{session_id: String.t(), epoch: pos_integer(), results: [result()]}
  @type failure :: {:error, :invalid_message | :unsupported_version}

  # @cc [owner:ghuntley,label:protocol;security] probe-wire-does-not-authorize-stop
  # Commands MUST bind immutable intent, source generation, key, challenge,
  # revision and absolute expiry. Only destination probes carry the enrolled
  # source endpoint. Consumers MUST check authority and bounded lease time;
  # parsing or source grant acknowledgement MUST NOT prove connectivity or stop.
  @spec command(term()) :: {:ok, command()} | failure()
  def command(
        %{
          "id" => id,
          "intent" => intent,
          "generation" => generation,
          "phase" => _phase,
          "public_key" => public,
          "challenge" => challenge,
          "revision" => revision,
          "expires_at" => expires,
          "source_endpoint" => endpoint
        } = value
      )
      when map_size(value) == 9 do
    with {:ok, receipt} <- result(Map.take(value, ~w(id phase challenge revision expires_at))),
         {:ok, intent} <- Relocation.intent(intent),
         true <- positive?(generation) and TransferSSH.public_key?(public),
         {:ok, endpoint} <- endpoint(receipt.phase, endpoint) do
      {:ok,
       %{
         id: id,
         intent: intent,
         generation: generation,
         phase: receipt.phase,
         public_key: public,
         challenge: challenge,
         revision: revision,
         expires_at: expires,
         source_endpoint: endpoint
       }}
    else
      _ -> failure()
    end
  end

  def command(_), do: failure()

  # @cc [owner:ghuntley,label:protocol;recovery] probe-result-correlates-role-and-lease
  # A result MUST match every immutable request correlation field. Grant and
  # probe results MUST NOT be interchangeable. Consumers MUST authenticate the
  # appropriate endpoint host and reject expired evidence before stopping a VM.
  @spec result(term()) :: {:ok, result()} | failure()
  def result(
        %{
          "id" => id,
          "phase" => phase,
          "challenge" => challenge,
          "revision" => revision,
          "expires_at" => expires
        } = value
      )
      when map_size(value) == 5 do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(challenge),
         true <- positive?(revision) and positive?(expires),
         phase when not is_nil(phase) <-
           Enum.find([:grant, :probe], &(Atom.to_string(&1) == phase)) do
      {:ok,
       %{id: id, phase: phase, challenge: challenge, revision: revision, expires_at: expires}}
    else
      _ -> failure()
    end
  end

  def result(_), do: failure()

  @spec matches?(command(), result()) :: boolean()
  def matches?(command, result),
    do: Map.take(command, [:id, :phase, :challenge, :revision, :expires_at]) == result

  @spec exchange(term()) :: {:ok, exchange()} | failure()
  def exchange(
        %{"version" => 4, "session_id" => id, "epoch" => epoch, "results" => values} = value
      )
      when map_size(value) == 4 do
    with true <- OverallsProtocol.uuid?(id) and positive?(epoch),
         {:ok, results} <- results(values),
         do: {:ok, %{session_id: id, epoch: epoch, results: results}},
         else: (_ -> failure())
  end

  def exchange(%{"version" => version}) when version != 4, do: {:error, :unsupported_version}
  def exchange(_), do: failure()

  @spec commands(term()) :: {:ok, [command()]} | failure()
  def commands(values), do: collection(values, &command/1)
  @spec results(term()) :: {:ok, [result()]} | failure()
  def results(values), do: collection(values, &result/1)
  @spec encode_command(command()) :: map()
  def encode_command(command) do
    command
    |> Map.drop([:intent, :phase])
    |> encode()
    |> Map.merge(%{
      "intent" => Relocation.encode_intent(command.intent),
      "phase" => Atom.to_string(command.phase)
    })
  end

  @spec encode_result(result()) :: map()
  def encode_result(result),
    do: result |> encode() |> Map.put("phase", Atom.to_string(result.phase))

  defp encode(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp endpoint(:grant, nil), do: {:ok, nil}
  defp endpoint(:probe, value), do: TransferSSH.endpoint(value)
  defp endpoint(_, _), do: failure()

  defp collection(values, decoder) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decoder.(value) do
        {:ok, decoded} ->
          if Enum.any?(acc, &(&1.id == decoded.id)),
            do: {:halt, failure()},
            else: {:cont, {:ok, [decoded | acc]}}

        _ ->
          {:halt, failure()}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp collection(_, _), do: failure()
  defp positive?(value), do: is_integer(value) and value in 1..@maximum
  defp failure, do: {:error, :invalid_message}
end
