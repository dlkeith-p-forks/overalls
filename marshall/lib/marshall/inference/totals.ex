defmodule Marshall.Inference.Totals do
  @moduledoc "Transactional completion aggregation; unknown usage stays explicitly countable."
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Daily

  # @cc [owner:ghuntley,label:concurrency;accounting] inference-exactly-once-totals
  # Callers MUST hold the request row lock and add totals only with its first
  # completion in the same transaction. A bucket lock MUST serialize concurrent
  # completions across replicas. Missing usage contributes to unknown_requests;
  # token sums represent only reported values, never an estimate of missing usage.
  @spec add!(struct(), map()) :: :ok
  def add!(request, completion) do
    day = DateTime.to_date(request.inserted_at)

    identity = [
      day: day,
      owner_id: request.owner_id,
      provider: request.provider,
      model: request.model
    ]

    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(identity))
    Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT pg_advisory_xact_lock($1)", [key], log: false)
    tokens = completion["tokens"]

    increments = %{
      requests: 1,
      unknown_requests: if(completion["completeness"] == "complete", do: 0, else: 1),
      input_tokens: Decimal.new(tokens["input_tokens"] || 0),
      output_tokens: Decimal.new(tokens["output_tokens"] || 0)
    }

    case Ledger.read!(Daily, identity) do
      [] ->
        Ledger.create!(Daily, :record, Map.merge(Map.new(identity), increments))

      [row] ->
        Ledger.update!(row, :add, %{
          requests: row.requests + 1,
          unknown_requests: row.unknown_requests + increments.unknown_requests,
          input_tokens: Decimal.add(row.input_tokens, increments.input_tokens),
          output_tokens: Decimal.add(row.output_tokens, increments.output_tokens)
        })
    end

    :ok
  end
end
