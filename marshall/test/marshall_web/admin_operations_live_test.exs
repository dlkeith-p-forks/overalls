defmodule MarshallWeb.AdminOperationsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User

  test "operational status is available to ordinary readers and redacted", %{conn: conn} do
    admin =
      Ash.Seed.seed!(User, %{
        email: "operations-admin-#{Ash.UUID.generate()}@example.test",
        administrator: false
      })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/operations")
    assert has_element?(view, "h1", "Platform status")
    assert has_element?(view, "h2", "Image catalog")
    assert has_element?(view, "h2", "DNS publications")
    refute has_element?(view, "h2", "Fleet monitor credentials")
    refute has_element?(view, "h2", "Certificate issuance")
    refute render(view) =~ "token_hash"
    refute render(view) =~ "private key"
    refute render(view) =~ "dns_proofs"
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
