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

  test "SCIM DELETE is wired to a soft retirement and reads hide retired identities" do
    assert {:ok, :scim_destroy} = AshScim.Info.scim_destroy_action(Marshall.Accounts.User)
    assert {:ok, :scim_read} = AshScim.Info.scim_read_action(Marshall.Accounts.User)

    destroy = Ash.Resource.Info.action(Marshall.Accounts.User, :scim_destroy)
    assert destroy.soft?

    assert Enum.any?(
             destroy.changes,
             &match?(%{change: {Marshall.Accounts.ScimLifecycle, [mode: :delete]}}, &1)
           )

    # Finalized and SCIM-deleted identities resolve through the real
    # retirement predicates rather than a model of them.
    now = DateTime.utc_now()
    expired = %Marshall.Accounts.User{active: false, scim_retirement_deadline: now}
    future = %{expired | scim_retirement_deadline: DateTime.add(now, 60, :second)}
    assert Marshall.Accounts.ScimRetirement.due?(expired, now)
    refute Marshall.Accounts.ScimRetirement.due?(future, now)
    refute Marshall.Accounts.ScimRetirement.due?(%{expired | active: true}, now)
    assert Marshall.Accounts.ScimRetirement.grace_seconds() == 7 * 24 * 60 * 60
  end

  test "SCIM deletion authority requires an expired inactive identity" do
    now = DateTime.utc_now()
    user_id = Ash.UUID.generate()

    deletion = %Marshall.Accounts.UserDeletion{
      user_id: user_id,
      kind: :scim_retirement,
      state: :scheduled,
      completed_at: nil
    }

    expired = %Marshall.Accounts.User{
      id: user_id,
      active: false,
      deleted_at: nil,
      scim_retirement_deadline: DateTime.add(now, -1, :second)
    }

    authorized? = &Marshall.Accounts.UserDeletion.machine_deletion_authorized?/3
    assert authorized?.(deletion, expired, now)

    refute authorized?.(
             deletion,
             %{expired | scim_retirement_deadline: DateTime.add(now, 1, :second)},
             now
           )

    refute authorized?.(deletion, %{expired | active: true}, now)
    refute authorized?.(%{deletion | state: :cancelled}, expired, now)
    refute authorized?.(deletion, %{expired | id: Ash.UUID.generate()}, now)

    # Administrator deletions still require the already retired identity.
    admin = %{deletion | kind: :administrator}
    refute authorized?.(admin, expired, now)
    assert authorized?.(admin, %{expired | deleted_at: now}, now)
  end
end
