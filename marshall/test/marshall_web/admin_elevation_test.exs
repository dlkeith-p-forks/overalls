defmodule MarshallWeb.AdminElevationTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.{AdminEvent, Security, User}
  alias Marshall.Compute.Ledger
  alias Marshall.PasskeyFixture, as: Fixture
  alias MarshallWeb.AdminElevation

  # @cc [owner:ghuntley,label:security;verification] admin-continuation-real-ceremony
  # Continuation tests MUST exercise the installed LiveView hook and real
  # WebAuthn signatures. Refusals MUST inspect target and audit state, rather
  # than treating a prompt or successful message delivery as authorization.
  test "button metadata is discarded and the exact action continues once", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()

    render_click(view, "set-role", %{
      "id" => target.id,
      "enabled" => "true",
      "value" => ""
    })

    assert_push_event(view, "admin-step-up-open", %{nonce: nonce})
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
    challenge = begin_verification(view, nonce)
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: true, completed: true})
    assert Security.current(target.id).administrator
    assert [%AdminEvent{kind: :grant}] = audit(target.id)
    assert Security.recent?(actor)

    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    assert [%AdminEvent{kind: :grant}] = audit(target.id)
  end

  test "an actual role button opens the passkey prompt", %{conn: conn} do
    target = Fixture.user()
    {_actor, _key, view} = administrator_view(conn)

    view |> element("#role-#{target.id}") |> render_click()
    assert_push_event(view, "admin-step-up-open", %{nonce: _})
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "a second action cannot replace the pending target or arguments", %{conn: conn} do
    {_actor, key, view} = administrator_view(conn)
    first = Fixture.user()
    second = Fixture.user()
    nonce = stage(view, first)
    render_click(view, "set-role", %{"id" => second.id, "enabled" => "true"})
    assert has_element?(view, "#flash-error", "Finish or cancel")
    challenge = begin_verification(view, nonce)

    # The assertion carries only credential proof; a supplied action is refused.
    payload = Fixture.assertion(challenge, key) |> Map.put("event", "delete-user")
    finish_verification(view, nonce, payload)
    assert_reply(view, %{ok: false})
    refute Security.current(first.id).administrator
    refute Security.current(second.id).administrator

    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: true, completed: true})
    assert Security.current(first.id).administrator
    refute Security.current(second.id).administrator
    assert [] == audit(second.id)
  end

  test "cancellation invalidates its challenge continuation", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)
    render_hook(view, "admin-step-up-cancel", %{})
    assert_reply(view, %{ok: true})
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "navigation clears the pending action", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)
    render_patch(view, "/admin/users?after=" <> Ash.UUID.generate())
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "demotion while the ceremony is open refuses continuation", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)
    Ledger.update!(actor, :assign_administrator, %{administrator: false})
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "a retired target is refused by the current domain state after verification", %{conn: conn} do
    {_actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)
    Ledger.update!(target, :security_state, %{deleted_at: Ledger.now()})
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: true, completed: true})
    assert has_element?(view, "#flash-error", "Could not change")
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "revocation while the ceremony is open halts at the stored login boundary", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        actor.__metadata__.token
      )

    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_redirect(view, "/sign-in")
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "a passkey generation change fences the original challenge", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)
    current = Security.current(actor.id)
    Ledger.update!(current, :security_state, %{mfa_generation: current.mfa_generation + 1})
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
  end

  test "expired or invalid assertions refuse, and a fresh challenge can retry", %{conn: conn} do
    {actor, key, view} = administrator_view(conn)
    target = Fixture.user()
    nonce = stage(view, target)
    challenge = begin_verification(view, nonce)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE account_passkey_challenges SET expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(challenge.id)]
    )

    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: false})
    refute Security.recent?(actor)
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
    challenge = begin_verification(view, nonce)

    finish_verification(
      view,
      nonce,
      Fixture.assertion(challenge, key, origin: "https://wrong.test")
    )

    assert_reply(view, %{ok: false})
    refute Security.current(target.id).administrator
    assert [] == audit(target.id)
    challenge = begin_verification(view, nonce)
    finish_verification(view, nonce, Fixture.assertion(challenge, key))
    assert_reply(view, %{ok: true, completed: true})
    assert Security.current(target.id).administrator
  end

  test "another socket's nonce cannot continue the action", %{conn: conn} do
    {actor, key, first_view} = administrator_view(conn)
    {:ok, second_view, _} = live(signed_in(conn, actor), "/admin/users")
    first_target = Fixture.user()
    second_target = Fixture.user()
    first_nonce = stage(first_view, first_target)
    second_nonce = stage(second_view, second_target)
    refute first_nonce == second_nonce
    challenge = begin_verification(first_view, first_nonce)
    finish_verification(second_view, first_nonce, Fixture.assertion(challenge, key))
    assert_reply(second_view, %{ok: false})
    finish_verification(first_view, first_nonce, Fixture.assertion(challenge, key))
    assert_reply(first_view, %{ok: true, completed: true})
    assert Security.current(first_target.id).administrator
    refute Security.current(second_target.id).administrator
    assert [] == audit(second_target.id)
  end

  test "malformed ceremonies clear pending state without administrative effects", %{conn: conn} do
    {_actor, _key, view} = administrator_view(conn)
    target = Fixture.user()

    for {event, params} <- [
          {"admin-step-up-begin", %{}},
          {"admin-step-up-begin", %{"nonce" => "wrong"}},
          {"admin-step-up-finish", %{}},
          {"admin-step-up-finish", %{"nonce" => "wrong", "payload" => %{}}}
        ] do
      stage(view, target)
      render_hook(view, event, params)
      assert_reply(view, %{ok: false})
      assert_push_event(view, "admin-step-up-close", %{})
      assert has_element?(view, "#flash-error", "expired or your access changed")
      refute Security.current(target.id).administrator
      assert [] == audit(target.id)
    end
  end

  test "canonical grammar rejects unknown arguments and oversized transport metadata" do
    id = Ash.UUID.generate()

    assert {:ok, %{"id" => ^id, "enabled" => "true"}} =
             AdminElevation.normalize("set-role", %{
               "id" => id,
               "enabled" => "true",
               "value" => ""
             })

    assert :error = AdminElevation.normalize("set-role", %{"id" => id, "enabled" => true})

    assert :error =
             AdminElevation.normalize("set-role", %{
               "id" => id,
               "enabled" => "true",
               "extra" => "anything"
             })

    assert :error =
             AdminElevation.normalize("set-role", %{
               "id" => id,
               "enabled" => "true",
               "value" => String.duplicate("x", 257)
             })

    assert :error = AdminElevation.normalize("anything", %{})
  end

  test "intent binding includes login, resource and request identity and expires after five minutes" do
    actor = Fixture.user(true)

    socket = %Phoenix.LiveView.Socket{
      view: MarshallWeb.Admin.LillyNodesLive,
      assigns: %{
        current_user: actor,
        live_action: :show,
        host_id: Ash.UUID.generate(),
        request_id: Ash.UUID.generate()
      },
      private: %{
        login_jti: Ash.UUID.generate(),
        security_return_to: "/admin/nodes/" <> Ash.UUID.generate()
      }
    }

    intent = AdminElevation.stage("evacuate", %{}, socket)
    assert AdminElevation.current?(intent, socket)
    refute AdminElevation.current?(%{intent | expires_at: System.monotonic_time(:second)}, socket)

    refute AdminElevation.current?(intent, %{
             socket
             | private: Map.put(socket.private, :login_jti, Ash.UUID.generate())
           })

    refute AdminElevation.current?(intent, %{
             socket
             | assigns: Map.put(socket.assigns, :request_id, Ash.UUID.generate())
           })

    refute AdminElevation.current?(intent, %{
             socket
             | assigns: Map.put(socket.assigns, :host_id, Ash.UUID.generate())
           })
  end

  @spec administrator_view(Plug.Conn.t()) :: {User.t(), map(), Phoenix.LiveViewTest.View.t()}
  defp administrator_view(conn) do
    {actor, token} = Fixture.login(Fixture.user(true))
    key = Fixture.register(actor)
    actor = Ash.Resource.put_metadata(actor, :token, token)
    {:ok, view, _} = live(signed_in(conn, actor), "/admin/users")
    {actor, key, view}
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, actor),
    do: conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

  @spec stage(Phoenix.LiveViewTest.View.t(), User.t()) :: String.t()
  defp stage(view, target) do
    render_click(view, "set-role", %{"id" => target.id, "enabled" => "true"})
    assert_push_event(view, "admin-step-up-open", %{nonce: nonce})
    nonce
  end

  @spec begin_verification(Phoenix.LiveViewTest.View.t(), String.t()) :: map()
  defp begin_verification(view, nonce) do
    render_hook(view, "admin-step-up-begin", %{"nonce" => nonce})
    assert_reply(view, %{ok: true, challenge: challenge})
    challenge
  end

  @spec finish_verification(Phoenix.LiveViewTest.View.t(), String.t(), map()) :: String.t()
  defp finish_verification(view, nonce, payload),
    do: render_hook(view, "admin-step-up-finish", %{"nonce" => nonce, "payload" => payload})

  @spec audit(String.t()) :: [AdminEvent.t()]
  defp audit(id), do: Ledger.read!(AdminEvent, target_id: id)
end
