defmodule Marshall.Galileo.AdminActions do
  @moduledoc "Administrator fleet integration listing without secret material."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Galileo.Integration

  @impl true
  def run(input, _options, _context) do
    Integration
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.map(
      &Map.take(&1, [:id, :name, :target, :peer, :owner_id, :team_id, :inserted_at, :updated_at])
    )
    |> Enum.drop_while(
      &(not is_nil(input.arguments[:after]) and &1.id != input.arguments[:after])
    )
    |> Enum.take(input.arguments.limit)
    |> then(&{:ok, &1})
  end
end
