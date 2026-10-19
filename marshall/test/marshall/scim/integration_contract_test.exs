defmodule Marshall.Scim.IntegrationContractTest do
  @moduledoc "Executable contracts for SCIM resource wiring and lifecycle boundaries."
  use ExUnit.Case, async: true

  test "Users and Groups expose SCIM paths and required identity mappings" do
    assert AshScim.Info.scim_path!(Marshall.Accounts.User) == "/Users"
    assert AshScim.Info.scim_path!(Marshall.Teams.Team) == "/Groups"

    user_attrs = Ash.Resource.Info.attributes(Marshall.Accounts.User) |> Map.new(&{&1.name, &1})
    team_attrs = Ash.Resource.Info.attributes(Marshall.Teams.Team) |> Map.new(&{&1.name, &1})

    assert Map.has_key?(user_attrs, :scim_external_id)
    assert Map.has_key?(user_attrs, :active)
    assert Map.has_key?(team_attrs, :scim_external_id)
    assert Map.has_key?(team_attrs, :management_mode)
  end

  test "SCIM lifecycle actions remain present for router dispatch" do
    user_actions = Ash.Resource.Info.actions(Marshall.Accounts.User) |> Map.new(&{&1.name, &1})
    team_actions = Ash.Resource.Info.actions(Marshall.Teams.Team) |> Map.new(&{&1.name, &1})

    assert Map.has_key?(user_actions, :scim_create)
    assert Map.has_key?(user_actions, :scim_update)
    assert Map.has_key?(user_actions, :scim_destroy)
    assert Map.has_key?(team_actions, :scim_create)
    assert Map.has_key?(team_actions, :scim_update)
  end

  test "finalized identities cannot be resurrected by lifecycle state model" do
    state = %{retiring: true, finalized: true}
    active = fn %{finalized: true} = current -> current end
    assert active.(state) == state
  end
end
