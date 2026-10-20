Code.require_file("../../marshall/scim/team_fixture.exs", __DIR__)

defmodule MarshallWeb.TeamsScimLiveTest do
  @moduledoc "Teams page under SCIM: read-only managed teams and the all-teams directory."
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Marshall.Scim.TeamFixture, as: Fixture
  alias Marshall.Teams.ServiceOwner

  test "a regular user sees every active team, with no service owner, while SCIM is disabled",
       %{conn: conn} do
    owner = Marshall.ComputeFixtures.user()
    viewer = Marshall.ComputeFixtures.user()
    name = Fixture.team_name()
    {:ok, team} = Marshall.Teams.create_team(%{name: name, idempotency_key: "a"}, actor: owner)

    {:ok, view, _} = live(signed_in(conn, viewer), ~p"/teams")

    assert has_element?(view, "#all-teams-#{team.id}", name)
    assert has_element?(view, "#team-form")
    refute has_element?(view, "#teams-managed-notice")
  end

  test "SCIM hides creation, membership and ownership controls and explains why",
       %{conn: conn} do
    alice = Marshall.ComputeFixtures.user()
    bob = Marshall.ComputeFixtures.user()
    outsider = Marshall.ComputeFixtures.user()
    token = Fixture.enable!()
    name = Fixture.team_name()

    {201, %{"id" => id}} =
      Fixture.request(token, :post, "/Groups", Fixture.group(name, [alice.id, bob.id]))

    {:ok, view, html} = live(signed_in(conn, alice), ~p"/teams")

    assert has_element?(view, "#teams-managed-notice")
    assert html =~ "Teams are managed by your identity provider."
    refute has_element?(view, "#team-form")
    refute has_element?(view, "#member-form")
    refute has_element?(view, "#transfer-offer-form")

    # My teams: the managed team and its visible members, never the service owner.
    assert has_element?(view, "#team-members")
    assert has_element?(view, "#team-member-#{alice.id}")
    assert has_element?(view, "#team-member-#{bob.id}")
    refute has_element?(view, "#team-member-#{ServiceOwner.id()}")
    assert has_element?(view, "#all-teams-#{id}", name)

    # Direct events are refused server-side as well.
    html = render_click(view, "create", %{"team" => %{"name" => Fixture.team_name()}})
    assert html =~ "Could not create this team."

    html =
      render_click(view, "member", %{
        "member" => %{"email" => to_string(outsider.email), "role" => "member"}
      })

    assert html =~ "Could not update this membership."
    refute has_element?(view, "#team-member-#{outsider.id}")

    # Someone outside every team still reads the all-teams directory.
    {:ok, outsider_view, _} = live(signed_in(conn, outsider), ~p"/teams")
    assert has_element?(outsider_view, "#all-teams-#{id}", name)
    assert has_element?(outsider_view, "#teams-managed-notice")
    refute has_element?(outsider_view, "#team-form")
  end

  test "a SCIM-managed team stays read-only after SCIM is disabled", %{conn: conn} do
    alice = Marshall.ComputeFixtures.user()
    token = Fixture.enable!()

    {201, _} =
      Fixture.request(token, :post, "/Groups", Fixture.group(Fixture.team_name(), [alice.id]))

    Fixture.disable!()
    {:ok, view, _} = live(signed_in(conn, alice), ~p"/teams")

    assert has_element?(view, "#team-form")
    assert has_element?(view, "#teams-managed-notice")
    refute has_element?(view, "#member-form")
    refute has_element?(view, "#transfer-offer-form")
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
