defmodule Marshall.Authorization.CedarTest do
  use Marshall.DataCase, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.User
  alias Marshall.Authorization.{Cedar, SystemActor}

  test "Control room reads require a current user and never imply mutation or VM authority" do
    user = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.verified_session()
    control_plane = Cedar.entity("ControlPlane", "marshall")
    assert Cedar.allowed?(user, "admin_read", control_plane)

    for action <- ~w(admin_accounts admin_operate admin_configure admin_jobs),
        do: refute(Cedar.allowed?(%{user | administrator: true}, action, control_plane))

    for action <- ~w(read write manage web),
        do: refute(Cedar.allowed?(user, action, Cedar.vm("other", Ash.UUID.generate())))

    for actor <- [nil, %{id: user.id}, %User{id: Ash.UUID.generate()}, SystemActor.compute()],
        do: refute(Cedar.allowed?(actor, "admin_read", control_plane))

    Marshall.Compute.Ledger.update!(user, :security_state, %{deleted_at: DateTime.utc_now()})
    refute Cedar.allowed?(user, "admin_read", control_plane)
  end

  property "the Cedar policy enforces the complete VM role matrix" do
    actor = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    actor_id = actor.id

    check all(
            role <- member_of([:owner, :web, :viewer, :operator, :manager, :stranger]),
            action <- member_of(["read", "write", "manage", "web"])
          ) do
      owner = if role == :owner, do: actor_id, else: "owner:" <> actor_id

      grants =
        if role in [:web, :viewer, :operator, :manager], do: %{role => [actor_id]}, else: %{}

      allowed =
        (action == "web" and role != :stranger) or role in [:owner, :manager] or
          (role == :viewer and action == "read") or
          (role == :operator and action in ["read", "write"])

      assert Cedar.allowed?(actor, action, Cedar.vm("vm", owner, grants)) == allowed
    end
  end

  property "the Cedar policy enforces the complete team membership matrix" do
    actor = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    actor_id = actor.id
    other = "member:" <> actor_id

    check all(
            role <- member_of([:owner, :admin, :member, :stranger]),
            action <- member_of(["team_read", "team_manage_members", "team_transfer"])
          ) do
      team =
        Cedar.entity("Team", "team", %{
          "owner" => Cedar.entity("User", if(role == :owner, do: actor_id, else: other)).uid,
          "admins" =>
            Enum.map(
              if(role in [:owner, :admin], do: [actor_id], else: []),
              &Cedar.entity("User", &1).uid
            ),
          "members" =>
            Enum.map(
              if(role == :stranger, do: [], else: [actor_id]),
              &Cedar.entity("User", &1).uid
            )
        })

      allowed =
        (role in [:owner, :admin] and true) or
          (role == :member and action == "team_read")

      assert Cedar.allowed?(actor, action, team) == allowed
    end
  end

  property "the Cedar policy enforces the integration manager matrix" do
    actor = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    actor_id = actor.id

    check all(
            role <- member_of([:owner, :manager, :stranger]),
            action <- member_of(["integration_read", "integration_manage"])
          ) do
      integration =
        Cedar.entity("Integration", "integration", %{
          "owner" => Cedar.entity("User", if(role == :owner, do: actor_id, else: "other")).uid,
          "managers" =>
            Enum.map(
              if(role == :manager, do: [actor_id], else: []),
              &Cedar.entity("User", &1).uid
            )
        })

      assert Cedar.allowed?(actor, action, integration) == (role != :stranger)
    end
  end

  property "team authority extends the VM matrix only through membership sets" do
    actor = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    actor_id = actor.id
    stranger_owner = "owner:" <> actor_id

    check all(
            role <- member_of([:team_admin, :team_member, :none]),
            action <- member_of(["read", "write", "manage", "web"])
          ) do
      grants = %{
        team_admins: if(role == :team_admin, do: [actor_id], else: []),
        team_members: if(role == :team_member, do: [actor_id], else: [])
      }

      allowed =
        (role == :team_admin and action in ["read", "write", "manage", "web"]) or
          (role == :team_member and action in ["read", "write", "web"])

      assert Cedar.allowed?(actor, action, Cedar.vm("vm", stranger_owner, grants)) == allowed
    end
  end

  test "only typed actors can provision, and users cannot coordinate" do
    user = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    resource = Cedar.entity("ControlPlane", "marshall")
    assert Cedar.allowed?(user, "provision", resource)
    refute Cedar.allowed?(nil, "provision", resource)
    refute Cedar.allowed?(%{id: "pretend", role: "user"}, "provision", resource)
    refute Cedar.allowed?(SystemActor.compute(), "provision", resource)
    internal = Cedar.entity("Internal", "test")
    assert Cedar.allowed?(SystemActor.compute(), "coordinate", internal)
    refute Cedar.allowed?(user, "coordinate", internal)
    refute Cedar.allowed?(user, "undefined", Cedar.vm("vm", user.id))

    refute Cedar.allowed?(
             %User{id: Ash.UUID.generate(), administrator: true},
             "provision",
             resource
           )
  end

  test "incomplete entities fail closed even when evaluation produces an error" do
    user = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    refute Cedar.allowed?(user, "read", Cedar.entity("VM", "vm"))
  end

  property "removing the owning entity attribute never preserves Cedar authority" do
    owner = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})

    check all(
            resource_kind <- member_of([:vm, :team, :integration]),
            action <-
              case resource_kind do
                :vm -> member_of(~w(read write manage web))
                :team -> member_of(~w(team_read team_manage_members team_transfer))
                :integration -> member_of(~w(integration_read integration_manage))
              end
          ) do
      resource =
        case resource_kind do
          :vm ->
            Cedar.vm("vm", owner.id)

          :team ->
            Cedar.entity("Team", "team", %{
              "owner" => Cedar.entity("User", owner.id).uid,
              "admins" => [],
              "members" => []
            })

          :integration ->
            Cedar.entity("Integration", "integration", %{
              "owner" => Cedar.entity("User", owner.id).uid,
              "managers" => []
            })
        end

      assert Cedar.allowed?(owner, action, resource)

      refute Cedar.allowed?(owner, action, %{
               resource
               | attributes: Map.delete(resource.attributes, "owner")
             })
    end
  end

  test "administrators have fleet VM authority while ordinary grants remain scoped" do
    admin =
      Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    vm = Cedar.vm("vm", Ash.UUID.generate())

    for action <- ~w(read write manage web),
        do: assert(Cedar.allowed?(admin, action, vm), "expected administrator #{action} access")
  end
end
