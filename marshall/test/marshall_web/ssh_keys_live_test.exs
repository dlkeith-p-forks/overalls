defmodule MarshallWeb.SSHKeysLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Marshall.ComputeFixtures
  alias Marshall.SSH

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "SSH key settings require sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/ssh-keys")
  end

  test "a signed-in user adds, identifies and removes their last public key", %{conn: conn} do
    owner = user()
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/settings/ssh-keys")
    assert has_element?(view, "#ssh-keys-empty")
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 42::256>>)
    view |> form("#ssh-key-form", key: %{label: "Laptop", public_key: key}) |> render_submit()
    assert {:ok, [record]} = SSH.list_keys(%{}, actor: owner)
    assert has_element?(view, "#ssh-key-#{record.id}", "Laptop")
    assert has_element?(view, "#ssh-key-#{record.id}", record.fingerprint)
    view |> element("#remove-ssh-key-#{record.id}") |> render_click()
    assert has_element?(view, "#ssh-keys-empty")
    assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
  end

  test "forged removal cannot revoke another account's key", %{conn: conn} do
    owner = user()
    other = user()
    text = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 43::256>>)
    {:ok, key} = SSH.add_key(%{public_key: text}, actor: owner)
    {:ok, view, _} = live(signed_in(conn, other), ~p"/settings/ssh-keys")
    render_click(view, "remove", %{"id" => key.id})
    assert {:ok, [^key]} = SSH.list_keys(%{}, actor: owner)
    assert has_element?(view, "#ssh-keys-empty")
  end

  test "revoked browser login cannot change keys through an existing LiveView", %{conn: conn} do
    owner = user()
    conn = signed_in(conn, owner)
    token = get_session(conn, "user_token")
    {:ok, view, _} = live(conn, ~p"/settings/ssh-keys")
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    text = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 44::256>>)
    view |> form("#ssh-key-form", key: %{public_key: text}) |> render_submit()
    assert_redirect(view, ~p"/sign-in")
    assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
  end

  test "accidentally pasted private material is cleared and excluded from debug diagnostics", %{
    conn: conn
  } do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    marker = "private-key-sentinel-#{Ash.UUID.generate()}"
    conn = signed_in(conn, user())

    logs =
      capture_log(fn ->
        {:ok, view, _} = live(conn, ~p"/settings/ssh-keys")

        html =
          view
          |> form("#ssh-key-form",
            key: %{public_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n" <> marker}
          )
          |> render_submit()

        refute html =~ marker
        assert has_element?(view, "#ssh-keys-empty")

        metadata =
          Process.info(view.pid, :dictionary) |> elem(1) |> Keyword.fetch!(:"$logger_metadata$")

        assert metadata[:marshall_authentication]
      end)

    refute String.contains?(logs, marker)
  end
end
