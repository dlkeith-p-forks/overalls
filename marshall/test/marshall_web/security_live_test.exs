defmodule MarshallWeb.SecurityLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  require Ash.Query
  alias Marshall.PasskeyFixture, as: Fixture

  test "enrolled login can use the application before verifying administrative access", %{
    conn: conn
  } do
    {actor, token} = Fixture.login(Fixture.user())
    key = Fixture.register(actor)
    conn = signed_in(conn, actor, token)
    {:ok, machines, _} = live(conn, "/machines")
    assert has_element?(machines, "#main-content")
    {:ok, reader, _} = live(conn, "/admin/users")
    assert has_element?(reader, "#admin-user-rows")
    {:ok, view, _} = live(conn, "/settings/security")
    assert has_element?(view, "#verify-passkey")
    refute has_element?(view, "#security-continue")
    {:ok, %{verified: true}} = Fixture.verify(actor, key)
    send(view.pid, :tick)
    assert has_element?(view, "#security-continue")
  end

  test "passkey verification offers the staged launch without automatic navigation", %{conn: conn} do
    {actor, token} = Fixture.login(Fixture.user())
    key = Fixture.register(actor)

    {:ok, pending} =
      MarshallWeb.PendingLaunch.new(
        "https://github.com/antithesishq/weaver",
        String.duplicate("a", 32)
      )

    conn = signed_in(conn, actor, token) |> put_session(MarshallWeb.PendingLaunch.key(), pending)
    {:ok, view, _} = live(conn, "/settings/security?return_to=%2Flaunch")
    refute has_element?(view, "#security-continue")
    {:ok, challenge} = Fixture.action(actor, :begin_verify)

    render_hook(view, "finish", %{
      "kind" => "verify",
      "payload" => Fixture.assertion(challenge, key)
    })

    assert has_element?(view, "#security-continue[href='/launch']")

    assert Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine, owner_id: actor.id) ==
             []
  end

  test "launch return requires valid pending input and ignores caller URL variants", %{conn: conn} do
    actor = Fixture.elevate(Fixture.user())

    for path <- ["/launch", "/launch?source=anything", "//evil.example/launch"] do
      {:ok, view, _} =
        live(
          signed_in(conn, actor, actor.__metadata__.token),
          "/settings/security?" <> URI.encode_query(%{return_to: path})
        )

      assert has_element?(view, "#security-continue[href='/overview']")
    end
  end

  test "admin reads remain available but a mutation prompts step-up", %{conn: conn} do
    {actor, token} = Fixture.login(Fixture.user(true))
    other = Fixture.user()
    {:ok, view, _} = live(signed_in(conn, actor, token), "/admin/users")
    assert has_element?(view, "#invite-user")
    render_click(view, "set-role", %{"id" => other.id, "enabled" => "true"})
    assert_redirect(view, "/settings/security?return_to=%2Fadmin%2Fusers")
    refute Marshall.Accounts.Security.current(other.id).administrator
  end

  test "first enrollment returns to the original page for an explicit retry", %{conn: conn} do
    {actor, token} = Fixture.login(Fixture.user(true))
    target = Fixture.user()
    {:ok, view, _} = live(signed_in(conn, actor, token), "/admin/users")
    render_click(view, "set-role", %{"id" => target.id, "enabled" => "true"})
    assert_redirect(view, "/settings/security?return_to=%2Fadmin%2Fusers")

    {:ok, security, _} =
      live(signed_in(conn, actor, token), "/settings/security?return_to=%2Fadmin%2Fusers")

    {:ok, challenge} = Fixture.action(actor, :begin_register)

    render_hook(security, "finish", %{
      "kind" => "register",
      "payload" => Fixture.registration(challenge, Fixture.authenticator())
    })

    assert_reply(security, %{ok: true})
    assert has_element?(security, "#security-continue[href='/admin/users']")
    refute Marshall.Accounts.Security.current(target.id).administrator
    assert admin_events(target.id) == []
  end

  test "lock now removes elevation without signing out and unsafe return paths are ignored", %{
    conn: conn
  } do
    actor = Fixture.elevate(Fixture.user(true))

    {:ok, view, _} =
      live(
        signed_in(conn, actor, actor.__metadata__.token),
        "/settings/security?return_to=https://evil.example"
      )

    assert has_element?(view, "#security-continue[href='/overview']")
    assert has_element?(view, "#lock-elevation")
    render_click(view, "credential", %{"operation" => "lock"})
    refute has_element?(view, "#lock-elevation")
    assert has_element?(view, "#security-continue")
  end

  test "rename updates the name and remove deletes a passkey through the mounted view", %{
    conn: conn
  } do
    actor = Fixture.elevate(Fixture.user())
    spare = Fixture.register(actor)
    {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings/security")
    key = passkey_id(actor, actor.__metadata__.test_authenticator)
    spare_id = passkey_id(actor, spare)

    assert has_element?(view, "#passkey-#{key} input[value='Test passkey']")
    assert has_element?(view, "#passkey-#{spare_id} input[value='Test passkey']")

    view
    |> form("#label-#{spare_id}")
    |> render_submit(%{"label" => "Backup passkey"})

    assert has_element?(view, "#passkey-#{spare_id} input[value='Backup passkey']")
    assert %{spare_id => "Backup passkey", key => "Test passkey"} == passkeys(actor.id)

    view |> element("#remove-#{spare_id}") |> render_click()
    refute has_element?(view, "#passkey-#{spare_id}")
    assert %{key => "Test passkey"} == passkeys(actor.id)
    assert has_element?(view, "#verification-status", "Passkey verified")
  end

  test "invalid or unverified credential changes are refused without crashing the view", %{
    conn: conn
  } do
    actor = Fixture.elevate(Fixture.user())
    {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings/security")
    key = passkey_id(actor, actor.__metadata__.test_authenticator)
    before = render(view)

    for label <- [String.duplicate("x", 81), "  "] do
      render_click(view, "credential", %{
        "operation" => "rename",
        "id" => key,
        "label" => label
      })

      assert has_element?(view, "#flash-error", "80 characters")
      assert %{key => "Test passkey"} == passkeys(actor.id)
    end

    # An exact 80-character name is accepted while 81 is refused.
    render_click(view, "credential", %{
      "operation" => "rename",
      "id" => key,
      "label" => String.duplicate("y", 80)
    })

    assert %{key => String.duplicate("y", 80)} == passkeys(actor.id)

    # A missing label takes the same graceful path.
    render_click(view, "credential", %{"operation" => "rename", "id" => key})
    assert has_element?(view, "#flash-error", "80 characters")
    assert %{key => String.duplicate("y", 80)} == passkeys(actor.id)

    # Unknown credentials refuse without a crash.
    render_click(view, "credential", %{
      "operation" => "remove",
      "id" => Ash.UUID.generate()
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#passkey-#{key}")

    # After lock-out, rename refuses with the same view still mounted.
    render_click(view, "credential", %{"operation" => "lock"})

    render_click(view, "credential", %{
      "operation" => "remove",
      "id" => key
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#passkey-#{key}")
    assert %{key => String.duplicate("y", 80)} == passkeys(actor.id)
    refute render(view) == before
  end

  test "administrator last-passkey removal refuses through the mounted view", %{conn: conn} do
    actor = Fixture.elevate(Fixture.user(true))
    {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings/security")
    [key] = Marshall.Compute.Ledger.read!(Marshall.Accounts.Passkey, user_id: actor.id)

    view |> element("#remove-#{key.id}") |> render_click()
    assert has_element?(view, "#flash-error", "at least one passkey")
    assert %{key.id => "Test passkey"} == passkeys(actor.id)
    assert Marshall.Accounts.Security.current(actor.id).mfa_enabled
  end

  @spec admin_events(String.t()) :: [Marshall.Accounts.AdminEvent.t()]
  defp admin_events(id),
    do: Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent, target_id: id)

  defp passkeys(id),
    do:
      Map.new(
        Marshall.Compute.Ledger.read!(Marshall.Accounts.Passkey, user_id: id),
        &{&1.id, &1.label}
      )

  defp passkey_id(actor, authenticator) do
    [record] =
      Marshall.Accounts.Passkey
      |> Ash.Query.filter(user_id == ^actor.id and credential_id == ^authenticator.id)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

    record.id
  end

  defp signed_in(conn, user, token),
    do:
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(
        Ash.Resource.put_metadata(user, :token, token)
      )
end
