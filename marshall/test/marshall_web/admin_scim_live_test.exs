defmodule MarshallWeb.AdminScimLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Scim.{Auth, Configuration}
  require Ash.Query

  test "anonymous visitors are sent to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/scim")
  end

  test "non-administrators cannot change SCIM configuration", %{conn: conn} do
    ordinary = Ash.Seed.seed!(User, %{email: "scim-ordinary-#{Ash.UUID.generate()}@example.test"})

    case live(signed_in(conn, ordinary), ~p"/admin/scim") do
      {:ok, view, _} ->
        refute has_element?(view, "#scim-generated-token")
        html = view |> form("#scim-enable-form") |> render_submit()
        assert html =~ "Administrative changes require an administrator."
        refute has_element?(view, "#scim-generated-token")
        assert config() == nil

      {:error, {:redirect, _}} ->
        assert config() == nil
    end
  end

  test "enabling shows a token exactly once and stores only its digest", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, admin()), ~p"/admin/scim")
    assert has_element?(view, "#scim-state", "[disabled]")

    view |> form("#scim-enable-form") |> render_submit()
    token = generated_token(view)
    assert "scim_" <> _ = token

    config = config()
    assert config.state == :enabled
    assert config.token_digest == Auth.digest(token)
    refute config.token_digest == token
    assert has_element?(view, "#scim-state", "[enabled]")

    # Any later render (here: an OIDC save) drops the plaintext token.
    view
    |> form("#scim-oidc-form", oidc: %{oidc_issuer: "", oidc_client_id: ""})
    |> render_submit()

    refute has_element?(view, "#scim-generated-token")
    refute render(view) =~ token

    {:ok, reloaded, html} = live(signed_in(build_conn(), admin()), ~p"/admin/scim")
    refute html =~ token
    refute has_element?(reloaded, "#scim-generated-token")
    assert config().token_digest == Auth.digest(token)
  end

  test "rotation replaces the digest and invalidates the previous token", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, admin()), ~p"/admin/scim")
    view |> form("#scim-enable-form") |> render_submit()
    first = generated_token(view)

    view |> form("#scim-rotate-form") |> render_submit()
    second = generated_token(view)

    refute first == second
    digest = config().token_digest
    assert digest == Auth.digest(second)
    refute digest == Auth.digest(first)

    assert {:error, _} = Auth.authenticate(bearer(first), [])
  end

  test "saving OIDC settings keeps the secret and never rotates the token", %{conn: conn} do
    seeded =
      Ash.Seed.seed!(Configuration, %{
        state: :enabled,
        token_digest: Auth.digest("scim_existing"),
        oidc_client_secret: "stored-secret"
      })

    {:ok, view, html} = live(signed_in(conn, admin()), ~p"/admin/scim")
    refute html =~ "stored-secret"
    assert html =~ "A client secret is set. Leave blank to keep it."

    view
    |> form("#scim-oidc-form",
      oidc: %{
        oidc_issuer: "https://idp.example.test",
        oidc_client_id: "overalls",
        oidc_client_secret: ""
      }
    )
    |> render_submit()

    refute has_element?(view, "#scim-generated-token")
    config = config()
    assert config.id == seeded.id
    assert config.oidc_issuer == "https://idp.example.test"
    assert config.oidc_client_id == "overalls"
    assert config.oidc_client_secret == "stored-secret"
    assert config.token_digest == Auth.digest("scim_existing")
    assert config.state == :enabled

    view
    |> form("#scim-oidc-form", oidc: %{oidc_client_secret: "replacement-secret"})
    |> render_submit()

    assert config().oidc_client_secret == "replacement-secret"
    refute render(view) =~ "replacement-secret"

    view
    |> form("#scim-oidc-form", oidc: %{clear_oidc_client_secret: "true"})
    |> render_submit()

    assert config().oidc_client_secret == nil
    assert render(view) =~ "No client secret is set."
  end

  test "a non-HTTPS issuer is refused without changing configuration", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, admin()), ~p"/admin/scim")

    html =
      view
      |> form("#scim-oidc-form", oidc: %{oidc_issuer: "http://idp.example.test"})
      |> render_submit()

    assert html =~ "Enter an absolute https:// issuer URL."
    assert config() == nil
  end

  test "disabling is a separate confirmed danger action", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, admin()), ~p"/admin/scim")
    view |> form("#scim-enable-form") |> render_submit()
    digest = config().token_digest

    assert has_element?(view, "#scim-disable.danger[data-confirm]")
    view |> form("#scim-disable-form") |> render_submit()

    refute has_element?(view, "#scim-generated-token")
    assert config().state == :disabled
    assert config().token_digest == digest
    assert has_element?(view, "#scim-enable-form")
  end

  test "status counts accounts pending retirement and retiring teams", %{conn: conn} do
    for _ <- 1..2 do
      Ash.Seed.seed!(User, %{
        email: "scim-retiring-#{Ash.UUID.generate()}@example.test",
        active: false,
        scim_retirement_deadline: DateTime.utc_now()
      })
    end

    owner = Ash.Seed.seed!(User, %{email: "scim-owner-#{Ash.UUID.generate()}@example.test"})

    Ash.Seed.seed!(Marshall.Teams.Team, %{
      name: "retiring-team",
      created_by_id: owner.id,
      management_mode: :retiring,
      scim_retirement_deadline: DateTime.utc_now()
    })

    {:ok, view, _} = live(signed_in(conn, admin()), ~p"/admin/scim")
    assert has_element?(view, "#scim-retiring-users", "2")
    assert has_element?(view, "#scim-retiring-teams", "1")
  end

  defp generated_token(view) do
    view
    |> element("#scim-generated-token code")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp bearer(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  defp config do
    Configuration
    |> Ash.Query.filter(key == "installation")
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "scim-admin-#{Ash.UUID.generate()}@example.test",
      administrator: true
    })
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
