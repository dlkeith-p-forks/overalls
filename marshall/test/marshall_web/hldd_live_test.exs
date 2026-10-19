defmodule MarshallWeb.HLDDLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures

  test "anonymous readers must sign in", %{conn: conn} do
    for path <- ["/hldd", "/hldd/security"] do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path)
    end
  end

  test "ordinary users can read all chapters and share navigation", %{conn: conn} do
    conn = signed_in(conn, user())
    {:ok, view, _} = live(conn, "/hldd")
    assert has_element?(view, "#nav-hldd[aria-current=page][href='/hldd']")
    assert has_element?(view, "#nav-reference h2", "Reference")
    assert has_element?(view, "#nav-reference a[href='/docs']", "Field notes")
    assert has_element?(view, "#nav-reference #nav-hldd")
    assert has_element?(view, "#nav-reference #nav-source-code")
    refute has_element?(view, "#nav-reference #nav-account")

    for chapter <- Marshall.Handbook.contents() do
      assert has_element?(view, "#hldd-index a[href='/hldd/#{chapter.id}']")
    end

    refute has_element?(view, "[data-hldd-section]")
    refute has_element?(view, "pre code.mermaid")

    # The Control room sidebar shows only administration links.
    {:ok, control, _} = live(conn, "/admin/nodes")
    refute has_element?(control, "#nav-account-section")
    refute has_element?(control, "#nav-reference")
    refute has_element?(control, "#nav-hldd")
    refute has_element?(control, "#nav-usage")
    assert has_element?(control, "nav[aria-label=Administration]")
  end

  test "direct visits and section navigation render only the selected body", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, user()), "/hldd/system")
    refute has_element?(view, "a[rel=prev]")
    assert has_element?(view, "a[rel=next][href='/hldd/control-plane']")

    for chapter <- Marshall.Handbook.contents() do
      render_patch(view, "/hldd/#{chapter.id}")
      assert has_element?(view, "[data-hldd-section='#{chapter.id}'] section##{chapter.id}")
      refute has_element?(view, "[data-hldd-section]:not([data-hldd-section='#{chapter.id}'])")
      assert has_element?(view, "a[aria-current=page][href='/hldd/#{chapter.id}']")
    end

    refute has_element?(view, "a[rel=next]")
    assert has_element?(view, "a[rel=prev][href='/hldd/domains']")
    render_patch(view, "/hldd/security")
    assert has_element?(view, "#security a[href='/hldd/coverage']")
    render_patch(view, "/hldd")
    assert has_element?(view, "#hldd-index")
    refute has_element?(view, "[data-hldd-section]")
  end

  test "unknown section identifiers return to contents", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/hldd"}}} =
             live(signed_in(conn, user()), "/hldd/not-a-chapter")
  end

  test "English handbook content keeps its language and direction inside localized chrome",
       %{conn: conn} do
    conn = signed_in(conn, user())

    for {locale, direction} <- [{"ar", "rtl"}, {"ja", "ltr"}] do
      localized_conn = put_req_header(conn, "accept-language", locale)
      {:ok, index, html} = live(localized_conn, "/hldd")
      document = LazyHTML.from_document(html)

      assert Enum.count(LazyHTML.query(document, "html[lang='#{locale}'][dir='#{direction}']")) ==
               1

      assert has_element?(index, "#hldd-index a[lang=en][dir=ltr]", "System overview")

      {:ok, section, _html} = live(localized_conn, "/hldd/system")
      assert has_element?(section, "article[data-hldd-section=system][lang=en][dir=ltr]")
      assert has_element?(section, "#system h1", "System overview")
      assert has_element?(section, ".hldd-contents a[lang=en][dir=ltr]", "System overview")
      assert has_element?(section, ".hldd-pagination span[lang=en][dir=ltr]")
    end
  end

  test "query parameters cannot load a chapter into the contents page", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, user()), "/hldd?section=options")
    assert has_element?(view, "#hldd-index")
    refute has_element?(view, "[data-hldd-section]")
  end

  test "revoked sessions cannot navigate back to the handbook", %{conn: conn} do
    conn = signed_in(conn, user())
    {:ok, view, _} = live(conn, "/hldd")
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(get_session(conn, "user_token"))
    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti=$1", [jti], log: false)
    render_patch(view, "/hldd/security")
    assert_redirect(view, "/sign-in")
  end

  test "public documentation cannot select handbook files", %{conn: conn} do
    for path <- ["/docs/hldd", "/docs/hldd.md", "/hldd.md"] do
      assert get(conn, path).status == 404
    end
  end

  # @cc [owner:ghuntley,label:verification] handbook-generated-current-reader
  # Generated chapter histories MUST exercise ordinary persisted users. Every
  # history MUST reject revocation, expiry and deletion on mounted navigation and
  # a fresh deep link, without relying on another user's login or cached authority.
  @tag :hegel
  test "ordinary reader chapter histories lose revoked expired and deleted login authority",
       %{conn: conn} do
    ids = Enum.map(Marshall.Handbook.contents(), & &1.id)

    Hegel.check(
      fn ->
        history = draw("history", list_of(member_of(ids), min_length: 1, max_length: 5))
        next_id = draw("next_id", member_of(ids))
        Hegel.assume(next_id != List.last(history))

        for invalidation <- [:revoke, :expire, :delete] do
          reader = user()
          refute reader.administrator
          signed_conn = signed_in(conn, reader)
          {:ok, view, _} = live(signed_conn, "/hldd")

          for id <- history do
            render_patch(view, "/hldd/#{id}")
            assert has_element?(view, "[data-hldd-section='#{id}']")
            refute has_element?(view, "[data-hldd-section]:not([data-hldd-section='#{id}'])")
          end

          {:ok, %{"jti" => jti}} =
            AshAuthentication.Jwt.peek(get_session(signed_conn, "user_token"))

          invalidate_login(invalidation, jti)
          render_patch(view, "/hldd/#{next_id}")
          assert_redirect(view, "/sign-in")

          assert {:error, {:redirect, %{to: "/sign-in"}}} =
                   live(signed_conn, "/hldd/#{next_id}")
        end
      end,
      test_cases: 100
    )
  end

  @spec invalidate_login(:revoke | :expire | :delete, String.t()) :: :ok
  defp invalidate_login(invalidation, jti) do
    statement =
      case invalidation do
        :revoke ->
          "UPDATE tokens SET purpose='revocation' WHERE jti=$1"

        :expire ->
          "UPDATE tokens SET expires_at=clock_timestamp() - interval '1 second' WHERE jti=$1"

        :delete ->
          "DELETE FROM tokens WHERE jti=$1"
      end

    %{num_rows: 1} = Ecto.Adapters.SQL.query!(Marshall.Repo, statement, [jti], log: false)
    :ok
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
