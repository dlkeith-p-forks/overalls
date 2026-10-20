defmodule MarshallWeb.ScimSignInLiveTest do
  use MarshallWeb.ConnCase, async: false

  alias Marshall.Scim.Configuration

  @magic_form "#user-magic-link-request-magic-link"

  test "without SCIM the magic-link form renders and no SSO link appears", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)
    assert query(html, @magic_form) != []
    assert query(html, "#scim-sso-sign-in") == []
    assert query(html, "#scim-sign-in") == []
  end

  test "SCIM with OIDC hides the magic-link form and links to single sign-on", %{conn: conn} do
    Ash.Seed.seed!(Configuration, %{
      state: :enabled,
      oidc_issuer: "https://idp.example.test",
      oidc_client_id: "overalls",
      oidc_client_secret: "secret"
    })

    html = conn |> get(~p"/sign-in") |> html_response(200)
    assert query(html, @magic_form) == []
    assert ["/auth/oidc/start"] = html |> lazy("#scim-sso-sign-in") |> LazyHTML.attribute("href")
    assert html =~ "Sign in with single sign-on"
    refute html =~ "secret\""
  end

  test "SCIM without OIDC hides the magic-link form and explains why", %{conn: conn} do
    Ash.Seed.seed!(Configuration, %{state: :enabled})

    html = conn |> get(~p"/sign-in") |> html_response(200)
    assert query(html, @magic_form) == []
    assert query(html, "#scim-sso-sign-in") == []
    assert query(html, "#scim-sso-unavailable") != []
  end

  test "the server-side magic-link fence still refuses requests under SCIM", %{conn: conn} do
    Ash.Seed.seed!(Configuration, %{state: :enabled})
    page = get(conn, ~p"/sign-in")

    response =
      post(recycle(page), "/auth/user/magic_link/request",
        user: %{email: "fenced-#{Ash.UUID.generate()}@example.test"}
      )

    refute get_session(response, "user_token")
    assert [] == Marshall.Compute.Ledger.read!(Marshall.Accounts.AuthEmail)
  end

  defp lazy(html, selector),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp query(html, selector), do: html |> lazy(selector) |> Enum.to_list()
end
