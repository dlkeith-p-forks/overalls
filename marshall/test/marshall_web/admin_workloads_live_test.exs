defmodule MarshallWeb.AdminWorkloadsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User

  test "workload inventory is available to signed-in users and exposes no terminal data", %{
    conn: conn
  } do
    ordinary = Ash.Seed.seed!(User, %{email: "workload-#{Ash.UUID.generate()}@example.test"})

    assert {:ok, _, _} = live(signed_in(conn, ordinary), ~p"/admin/workloads")

    admin =
      Ash.Seed.seed!(User, %{
        email: "workload-admin-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/workloads")
    assert has_element?(view, "h1", "Fleet workloads")
    refute render(view) =~ "token_hash"
    refute render(view) =~ "terminal_bytes"
  end

  defp signed_in(conn, user) do
    user = if user.administrator, do: Marshall.PasskeyFixture.verified_session(user), else: user

    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
