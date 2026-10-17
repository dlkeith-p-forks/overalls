defmodule Marshall.Compute.AdvanceEvacuation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(%{arguments: %{primary_key: %{"id" => id} = key}}, _, _) when map_size(key) == 1,
    do: advance(id)

  def run(_, _, _), do: {:error, "Invalid evacuation identity"}

  defp advance(id) do
    case Marshall.Compute.Evacuations.advance(id) do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end
end
