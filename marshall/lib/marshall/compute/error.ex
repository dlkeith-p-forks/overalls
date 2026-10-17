defmodule Marshall.Compute.Error do
  @moduledoc "A stable reason for a rejected coordinator transaction."
  use Splode.Error, fields: [:reason], class: :invalid
  @impl true
  def message(error), do: "Compute request rejected: #{error.reason}"
end
