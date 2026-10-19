defmodule MarshallWeb.SSHApprovalLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Marshall.ComputeFixtures, only: [user: 0]
  alias Marshall.Authorization.SystemActor
  alias Marshall.SSH

  setup do
    {gateway_token, _} = SSH.Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "browser", token: gateway_token},
        actor: SystemActor.compute()
      )

    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 7::256>>)

    {:ok, pending} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    %{gateway_token: gateway_token, pending: pending, owner: user()}
  end

  test "anonymous approval preserves a validated return path without consuming it", c do
    conn = get(c.conn, c.pending.approval_path)
    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, :return_to) == c.pending.approval_path
    assert {:ok, %{status: "pending"}} = status(c)

    for {locale, message} <- [{"en", "Unavailable"}, {"ar", "غير متاح"}, {"ja", "利用不可"}] do
      refusal =
        build_conn()
        |> put_req_header("accept-language", locale)
        |> get("/ssh/approve/not-a-token")

      assert response(refusal, 404) == message
      assert get_resp_header(refusal, "content-language") == [locale]
      refute get_session(refusal, :return_to)
    end
  end

  test "viewing the fingerprint does not approve; an explicit click binds the signed-in owner",
       c do
    {:ok, view, _} = live(signed_in(c.conn, c.owner), c.pending.approval_path)
    assert has_element?(view, "#ssh-approval-fingerprint", c.pending.fingerprint)
    assert {:ok, %{status: "pending"}} = status(c)
    view |> form("#ssh-approval-form", key: %{label: "Laptop"}) |> render_submit()
    assert_redirect(view, ~p"/settings#ssh-keys")
    assert {:ok, %{status: "authenticated", user: %{id: id}}} = status(c)
    assert id == c.owner.id
    {:ok, replay, _} = live(signed_in(build_conn(), c.owner), c.pending.approval_path)
    refute has_element?(replay, "#approve-ssh-key")
  end

  test "revoked browser login cannot approve through an already mounted form", c do
    conn = signed_in(c.conn, c.owner)
    token = get_session(conn, "user_token")
    {:ok, view, _} = live(conn, c.pending.approval_path)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    view |> form("#ssh-approval-form", key: %{label: "Laptop"}) |> render_submit()
    assert_redirect(view, ~p"/sign-in")
    assert {:ok, %{status: "pending"}} = status(c)
  end

  test "approval URL tokens do not reach HTTP or LiveView debug logs", c do
    conn = signed_in(c.conn, c.owner)
    old_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log(fn ->
        {:ok, view, _} = live(conn, c.pending.approval_path)
        assert has_element?(view, "#approve-ssh-key")
      end)

    token = String.replace_prefix(c.pending.approval_path, "/ssh/approve/", "")
    refute String.contains?(logs, token)
  end

  defp status(c),
    do:
      SSH.session_status(
        %{gateway_token: c.gateway_token, session_token: c.pending.session_token},
        actor: SystemActor.compute()
      )

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
