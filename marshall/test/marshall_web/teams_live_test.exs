defmodule MarshallWeb.TeamsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Marshall.Accounts.User

  test "creating a team and setting membership emits catalogued events", %{conn: conn} do
    owner = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    member = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/teams")

    logs =
      capture_log([metadata: [:event, :operation_status, :team_id, :user_id]], fn ->
        render_click(view, "create", %{"team" => %{"name" => "edge-crew"}})
      end)

    assert logs =~ "event=team.membership_changed"
    assert event_count(logs, "team.membership_changed") == 1
    assert logs =~ "operation_status=created"
    assert logs =~ owner.id

    {:ok, [team]} = Marshall.Teams.list_teams(actor: owner)
    assert team.name == "edge-crew"

    member_logs =
      capture_log([metadata: [:event, :operation_status, :user_id]], fn ->
        render_click(view, "select", %{"id" => team.id})

        render_click(view, "member", %{
          "member" => %{"email" => member.email, "role" => "member"}
        })
      end)

    assert member_logs =~ "event=team.membership_changed"
    assert event_count(member_logs, "team.membership_changed") == 1
    assert member_logs =~ "operation_status=member"
    assert member_logs =~ member.id

    {:ok, member_view, _} = live(signed_in(conn, member), ~p"/teams")

    transfer_logs =
      capture_log([metadata: [:event, :operation_status, :state]], fn ->
        render_click(view, "transfer_offer", %{"transfer" => %{"email" => member.email}})
        {:ok, [transfer]} = Marshall.Teams.list_team_transfers(%{team_id: team.id}, actor: owner)
        render_click(member_view, "transfer", %{"action" => "decline", "id" => transfer.id})

        render_click(view, "transfer_offer", %{"transfer" => %{"email" => member.email}})
        {:ok, [transfer]} = Marshall.Teams.list_team_transfers(%{team_id: team.id}, actor: owner)
        render_click(view, "transfer", %{"action" => "cancel", "id" => transfer.id})

        render_click(view, "transfer_offer", %{"transfer" => %{"email" => member.email}})
        {:ok, [transfer]} = Marshall.Teams.list_team_transfers(%{team_id: team.id}, actor: owner)
        render_click(member_view, "transfer", %{"action" => "accept", "id" => transfer.id})
      end)

    assert event_count(transfer_logs, "team.transfer_changed") == 6
    assert event_count(transfer_logs, "team.membership_changed") == 2
    assert transfer_logs =~ "operation_status=owner"
    assert transfer_logs =~ "operation_status=admin"
  end

  test "foreign team names refuse creation without showing false success", %{conn: conn} do
    owner = Marshall.ComputeFixtures.user()
    outsider = Marshall.ComputeFixtures.user()

    {:ok, team} =
      Marshall.Teams.create_team(%{name: "claimed-name", idempotency_key: "owner"}, actor: owner)

    {:ok, view, _} = live(signed_in(conn, outsider), ~p"/teams")

    html = render_click(view, "create", %{"team" => %{"name" => team.name}})
    assert html =~ "Could not create this team."
    refute html =~ "Team claimed-name created."
    assert {:ok, []} = Marshall.Teams.list_teams(actor: outsider)
    refute Marshall.Teams.member?(team.id, outsider.id)

    html = render_click(view, "create", %{"team" => %{"name" => "available-name"}})
    assert html =~ "Team available-name created."

    assert {:ok, [%{name: "available-name", role: :owner}]} =
             Marshall.Teams.list_teams(actor: outsider)
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp event_count(logs, event),
    do: logs |> String.split("event=#{event}") |> length() |> Kernel.-(1)
end
