defmodule Marshall.SSH.Error do
  @moduledoc "Fixed SSH domain rejection reasons, without request or credential data."
  use Splode.Error, fields: [:reason], class: :invalid
  @impl true
  def message(error), do: "SSH request rejected: #{error.reason}"

  @spec result({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def result({:error, reason}) when is_atom(reason), do: {:error, exception(reason: reason)}
  def result(result), do: result
end
