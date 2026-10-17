defmodule Marshall.Compute.AdvanceDrain do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(%{arguments: %{primary_key: %{"id" => id} = key}}, _, _) when map_size(key) == 1 do
    case Marshall.Compute.Drains.advance(id) do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      result ->
        result
    end
  end

  def run(_, _, _), do: {:error, "Invalid drain identity"}
end
