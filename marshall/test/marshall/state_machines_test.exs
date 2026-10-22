defmodule Marshall.StateMachinesTest do
  # @cc [owner:ghuntley,label:verification] state-machine-attribute-closed
  # Every resource governed by AshStateMachine MUST change its state attribute
  # only through transitions: no create or update action may accept it.
  use ExUnit.Case, async: true

  @spec machines() :: [module()]
  defp machines do
    for domain <- Application.fetch_env!(:marshall, :ash_domains),
        resource <- Ash.Domain.Info.resources(domain),
        AshStateMachine in Spark.extensions(resource),
        do: resource
  end

  test "state-machine resources exist in every governed domain" do
    resources = machines()

    for expected <- [
          Marshall.Threads.Thread,
          Marshall.Artifacts.Artifact,
          Marshall.Artifacts.ViewTicket,
          Marshall.Artifacts.PublishRequest
        ] do
      assert expected in resources
    end
  end

  # Pre-existing actions owned by other features that set state directly. They
  # are tracked here so no new resource can join them; remove an entry once its
  # resource moves to transitions.
  @existing_exceptions [
    "Marshall.Scim.Configuration.create",
    "Marshall.Redaction.Shard.transition",
    "Marshall.Agents.ThreadSubscription.subscribe",
    "Marshall.Agents.ThreadReceiver.register"
  ]

  test "no action accepts a state machine's state attribute" do
    violations =
      for resource <- machines(),
          state = AshStateMachine.Info.state_machine_state_attribute!(resource),
          action <- Ash.Resource.Info.actions(resource),
          action.type in [:create, :update],
          state in (action.accept || []),
          do: "#{inspect(resource)}.#{action.name}"

    assert violations -- @existing_exceptions == []
  end
end
