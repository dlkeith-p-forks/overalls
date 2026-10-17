defmodule Marshall.Compute.EvacuationActions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _, %{actor: actor}) do
    result =
      case input.action.name do
        :request_for_admin -> Marshall.Compute.Evacuations.request(input.arguments, actor)
        :control_for_admin -> Marshall.Compute.Evacuations.control(input.arguments, actor)
        :approve_for_admin -> Marshall.Compute.Evacuations.approve(input.arguments, actor)
        :replan_for_admin -> Marshall.Compute.Evacuations.replan(input.arguments, actor)
      end

    case result do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end
end
