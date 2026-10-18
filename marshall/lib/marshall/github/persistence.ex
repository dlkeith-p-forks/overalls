defmodule Marshall.GitHub.Persistence do
  @moduledoc "Bounded retries of idempotent database settlement, without provider re-exchange."
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:recovery;security] github-exact-pair-commit-retry
  # A received token pair MUST remain in the caller across bounded database
  # retries. The closure MUST reread its attempt and accept an already staged
  # identical pair after a lost commit acknowledgement. It MUST NOT invoke the
  # provider or exchange/refresh a token again.
  @spec transaction((-> value), pos_integer()) :: {:ok, value} | {:error, term()}
        when value: term()
  def transaction(fun, attempts \\ 3) when is_function(fun, 0) and attempts in 1..3 do
    case commit(fun) do
      {:error, :unavailable} when attempts > 1 -> transaction(fun, attempts - 1)
      result -> result
    end
  end

  @spec commit((-> value)) :: {:ok, value} | {:error, term()} when value: term()
  defp commit(fun) do
    case Ledger.transaction(fun) do
      {:error, reason} when not is_atom(reason) -> {:error, :unavailable}
      result -> result
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
