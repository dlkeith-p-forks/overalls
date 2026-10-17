defmodule Marshall.Ingress.Error do
  @moduledoc "Fixed ingress rejection reasons without request or credential data."
  use Splode.Error, fields: [:reason], class: :invalid
  @impl true
  def message(error), do: "Ingress request rejected: #{error.reason}"

  def result({:error, reason}) when is_atom(reason), do: {:error, exception(reason: reason)}
  def result(result), do: result
end
