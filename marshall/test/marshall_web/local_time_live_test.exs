defmodule MarshallWeb.LocalTimeLiveTest do
  @moduledoc "Other people's local time and viewer-zone timestamps across pages (ADR-0195)."
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute}
  alias Marshall.Accounts.User

  @adelaide "Australia/Adelaide"
  @london "Europe/London"

  defp with_zone(user, zone), do: Ash.Seed.update!(user, %{time_zone: zone})

  defp admin,
    do: Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: true})

  test "timestamps render in the viewer zone with the UTC instant on hover", %{conn: conn} do
    user = with_zone(user(), @adelaide)
    {:ok, view, _} = live(signed_in(conn, user), ~p"/overview")
    assert has_element?(view, ".overview-refresh time.timestamp[data-zone='#{@adelaide}']")
    assert render(element(view, ".overview-refresh time.timestamp")) =~ ~r/\d{2}:\d{2} AC[DS]T</
    assert has_element?(view, ".overview-refresh time.timestamp[title$='UTC']")

    {:ok, _} =
      Marshall.SSH.add_key(%{public_key: Marshall.SharingSurfacesFixture.key_text()}, actor: user)

    {:ok, keys, _} = live(signed_in(conn, user), ~p"/settings")
    assert has_element?(keys, "time.timestamp[data-zone='#{@adelaide}'][title$='UTC']")
  end

  test "team members show their local time and the difference from the viewer", %{conn: conn} do
    owner = with_zone(user(), @london)
    member = with_zone(user(), @adelaide)
    unsaved = user()

    {:ok, team} =
      Marshall.Teams.create_team(%{name: "tz-crew", idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    for person <- [member, unsaved] do
      {:ok, _} =
        Marshall.Teams.set_team_member(
          %{
            team_id: team.id,
            email: person.email,
            role: :member,
            idempotency_key: Ash.UUID.generate()
          },
          actor: owner
        )
    end

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/teams")
    render_click(view, "select", %{"id" => team.id})

    assert has_element?(view, "#team-member-#{member.id} .person-email", to_string(member.email))

    assert render(element(view, "#team-member-#{member.id} .local-time")) =~
             ~r/\d+h 30m ahead of you/

    assert render(element(view, "#team-member-#{member.id} .local-time")) =~ "local time"
    assert has_element?(view, "#team-member-#{owner.id} .local-time", "same time as you")
    refute has_element?(view, "#team-member-#{unsaved.id} .local-time")

    {:ok, _} = Marshall.Teams.Coordinator.offer(team.id, to_string(member.email), owner)

    render_click(view, "select", %{"id" => team.id})
    assert has_element?(view, "#transfer-to .local-time", "ahead of you")
  end

  test "machine access and the machines list show the owner's and grantees' local time", %{
    conn: conn
  } do
    host_fixture()
    owner = with_zone(user(), @adelaide)
    viewer = with_zone(user(), @london)
    {:ok, vm} = Compute.provision(request(), actor: owner)

    {:ok, _} =
      Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(viewer.email),
          role: :viewer,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    {:ok, access, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/access")
    assert has_element?(access, "#machine-owner-person .local-time", "same time as you")
    assert render(element(access, "#grants .local-time")) =~ ~r/\d+h 30m behind you/

    {:ok, list, _} = live(signed_in(conn, viewer), ~p"/machines")
    assert has_element?(list, "#machine-owner-#{vm.id} .person-email", to_string(owner.email))

    assert render(element(list, "#machine-owner-#{vm.id} .local-time")) =~
             ~r/\d+h 30m ahead of you/

    {:ok, mine, _} = live(signed_in(conn, owner), ~p"/machines")
    refute has_element?(mine, "#machine-owner-#{vm.id}")
    assert has_element?(mine, "#machines td[data-label=Access]", "Owner")
  end

  test "thread participants show their local time", %{conn: conn} do
    host_fixture()
    owner = with_zone(user(), @adelaide)
    collaborator = with_zone(user(), @london)

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Share across zones",
          machine_spec: request(),
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")
    view |> element("#thread-share-toggle") |> render_click()

    view
    |> form("#thread-access-form",
      access: %{email: to_string(collaborator.email), role: "viewer"}
    )
    |> render_submit()

    assert has_element?(view, "#thread-grant-owner-person .local-time", "same time as you")
    assert render(element(view, "#thread-grant-items .local-time")) =~ ~r/\d+h 30m behind you/
  end

  test "administrators see saved local times on users and access pages", %{conn: conn} do
    administrator = with_zone(admin(), @london)
    person = with_zone(user(), @adelaide)
    silent = user()

    {:ok, users, _} = live(signed_in(conn, administrator), ~p"/admin/users")

    assert render(element(users, "#admin-user-local-time-#{person.id}")) =~
             ~r/\d+h 30m ahead of you/

    refute has_element?(users, "#admin-user-local-time-#{silent.id}")

    host_fixture()
    {:ok, vm} = Compute.provision(request(), actor: person)

    {:ok, _} =
      Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(silent.email),
          role: :viewer,
          idempotency_key: Ash.UUID.generate()
        },
        actor: person
      )

    {:ok, _} =
      Marshall.SSH.add_key(%{public_key: Marshall.SharingSurfacesFixture.key_text()},
        actor: person
      )

    {:ok, access, _} = live(signed_in(conn, administrator), ~p"/admin/access")
    refute has_element?(access, "#admin-grants .local-time")
    assert render(element(access, "#admin-keys .local-time")) =~ ~r/\d+h 30m ahead of you/
    assert has_element?(access, "#admin-keys time.timestamp[data-zone='#{@london}']")

    {:ok, workloads, _} = live(signed_in(conn, administrator), ~p"/admin/workloads")

    assert render(element(workloads, "#admin-workload-#{vm.id}-owner .local-time")) =~
             "ahead of you"
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
