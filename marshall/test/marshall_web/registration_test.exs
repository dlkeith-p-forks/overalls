defmodule MarshallWeb.RegistrationTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.AuthEmail
  alias Marshall.Compute.Ledger

  test "sign-in accepts safe domains and keeps request feedback generic", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/sign-in")

    assert has_element?(view, "label", "Email")
    assert has_element?(view, ".auth-panel")
    assert has_element?(view, "button.console-button.primary")
    refute has_element?(view, "img[src*='ash-hq']")
    # ADR-0161: the authentication overrides leave no utility-framework class behind.
    refute render(view) =~ ~r/class="[^"]*\b(?:dark:|rounded|px-|py-|text-gray)/

    local = Ash.UUID.generate() |> String.replace("-", "") |> binary_part(0, 20)

    for email <- ["new-#{local}@example.test", "outside@elsewhere.test"] do
      view
      |> form("#user-magic-link-request-magic-link", user: %{email: email})
      |> render_submit()

      assert has_element?(
               view,
               "[role=alert]",
               "Your account will be created automatically when you sign in."
             )

      refute render(view) =~ "If this user exists in our database"
    end

    assert length(Ledger.read!(AuthEmail)) == 2
  end
end
