defmodule MarshallWeb.AccountLiveTest do
  @moduledoc """
  The merged account page at /settings (ADR-0196): profile, sign-in passkeys
  and SSH keys as sections of one LiveView behind the security mount.
  """
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Marshall.ComputeFixtures
  require Ash.Query
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.PasskeyFixture, as: Fixture
  alias Marshall.SSH

  @adelaide "Australia/Adelaide"
  @london "Europe/London"

  describe "page and navigation" do
    test "anonymous visitors must sign in and the old settings pages are gone", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")

      for path <- ["/settings/profile", "/settings/security", "/settings/ssh-keys"] do
        assert get(conn, path).status == 404
      end
    end

    test "the page renders every section behind one Account navigation entry", %{conn: conn} do
      {:ok, view, _} = live(signed_in(conn, user()), ~p"/settings")

      assert has_element?(view, "#nav-account[href='/settings'][aria-current=page]")
      assert has_element?(view, "#nav-usage[href='/usage']")
      refute has_element?(view, "#nav-profile")
      refute has_element?(view, "#workspace-sidebar a[href='/settings/security']")
      refute has_element?(view, "#workspace-sidebar a[href='/settings/ssh-keys']")
      refute has_element?(view, "#workspace-sidebar a[href='/settings/profile']")
      assert has_element?(view, "#account-local-clock + a.nav-hint[href='/settings#profile']")

      for anchor <- ["profile", "security", "ssh-keys"] do
        assert has_element?(view, "#account-index a[href='##{anchor}']")

        assert has_element?(
                 view,
                 "section##{anchor}.account-section[aria-labelledby='#{anchor}-title']"
               )
      end

      assert has_element?(view, "#profile #profile-account")
      assert has_element?(view, "#profile #time-zone-form")
      assert has_element?(view, "#security #verification-status")
      assert has_element?(view, "#security #passkey-ceremony #add-passkey")
      assert has_element?(view, "#security #passkey-ceremony #verify-passkey")
      assert has_element?(view, "#security #passkeys-empty")
      assert has_element?(view, "#ssh-keys #ssh-keys-empty")
      assert has_element?(view, "#ssh-keys #ssh-key-form #add-ssh-key")
      assert has_element?(view, ".workspace-breadcrumb", "Account")
    end

    # @cc [owner:ghuntley,label:security;verification] account-page-strict-mount-pin
    # The merged page MUST keep exactly the privacy tag and the :security
    # required-login mount; a change to :live_user_optional, to :current_user
    # or to no login hook MUST fail this test.
    test "the merged page keeps the strict security mount of the former Security page" do
      ids = Enum.map(MarshallWeb.AccountLive.__live__().lifecycle.mount, & &1.id)

      assert ids == [
               {MarshallWeb.AuthenticationPrivacy, :default},
               {MarshallWeb.LiveUserAuth, :security}
             ]

      assert %{phoenix_live_view: {MarshallWeb.AccountLive, :index, _, _}} =
               Phoenix.Router.route_info(MarshallWeb.Router, "GET", "/settings", "")
    end

    test "an unknown event is refused without touching any section", %{conn: conn} do
      owner = user()
      {:ok, view, _} = live(signed_in(conn, owner), ~p"/settings")
      render_click(view, "delete-everything", %{})
      assert has_element?(view, "#flash-error", "Invalid request.")
      assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
      assert saved_zone(owner.id) == nil
    end
  end

  describe "profile section" do
    test "the profile saves, preselects and clears the time zone", %{conn: conn} do
      user = user()

      {:ok, view, _} = live(signed_in(conn, user) |> browser(@adelaide), ~p"/settings")

      assert has_element?(view, "#profile-account", to_string(user.email))

      assert has_element?(
               view,
               "#time-zone-status[data-source=browser]",
               "Detected from your browser"
             )

      assert has_element?(
               view,
               "#profile_time_zone option[selected][value='#{@adelaide}']",
               "Adelaide"
             )

      assert has_element?(view, "#profile_time_zone option[value='#{@adelaide}']", "(GMT+")

      assert has_element?(
               view,
               "#profile-local-clock[data-zone='#{@adelaide}'][data-zone-source=browser]"
             )

      assert has_element?(view, "#account-local-clock[data-zone='#{@adelaide}']")
      refute has_element?(view, "#clear-time-zone")

      view
      |> form("#time-zone-form", profile: %{time_zone: "Pacific/Chatham"})
      |> render_submit()

      assert saved_zone(user.id) == "Pacific/Chatham"
      assert has_element?(view, "#time-zone-status[data-source=saved]", "Saved: Pacific/Chatham")
      assert has_element?(view, "#profile_time_zone option[selected][value='Pacific/Chatham']")
      assert has_element?(view, "#profile-local-clock[data-zone='Pacific/Chatham']")
      assert render(view) =~ "Time zone saved."

      view |> element("#clear-time-zone") |> render_click()
      assert saved_zone(user.id) == nil
      assert has_element?(view, "#time-zone-status[data-source=browser]")
      assert has_element?(view, "#profile_time_zone option[selected][value='#{@adelaide}']")
    end

    test "a zone outside the list is refused and the saved zone stays", %{conn: conn} do
      user = with_zone(user(), @london)
      {:ok, view, _} = live(signed_in(conn, user), ~p"/settings")

      render_submit(view, "save_time_zone", %{"profile" => %{"time_zone" => "Mars/Olympus"}})
      assert render(view) =~ "Choose a time zone from the list."
      assert saved_zone(user.id) == @london

      assert has_element?(
               view,
               "#profile-local-clock[data-zone='#{@london}'][data-zone-source=saved]"
             )
    end

    test "the viewer zone resolves saved, then browser, then UTC", %{conn: conn} do
      saved = with_zone(user(), @london)
      unsaved = user()
      clock = "#profile-local-clock"

      {:ok, view, _} = live(signed_in(conn, saved) |> browser(@adelaide), ~p"/settings")
      assert has_element?(view, "#{clock}[data-zone='#{@london}'][data-zone-source=saved]")
      assert has_element?(view, "#account-local-clock[data-zone='#{@london}']")

      {:ok, view, _} = live(signed_in(conn, unsaved) |> browser(@adelaide), ~p"/settings")
      assert has_element?(view, "#{clock}[data-zone='#{@adelaide}'][data-zone-source=browser]")

      {:ok, view, _} = live(signed_in(conn, unsaved) |> browser("Mars/Olympus"), ~p"/settings")
      assert has_element?(view, "#{clock}[data-zone='Etc/UTC'][data-zone-source=utc]")

      {:ok, view, _} = live(signed_in(conn, unsaved), ~p"/settings")
      assert has_element?(view, "#{clock}[data-zone='Etc/UTC'][data-zone-source=utc]")

      # Every page carries the resolved zone into the account menu clock.
      {:ok, view, _} = live(signed_in(conn, unsaved) |> browser(@adelaide), ~p"/overview")
      assert has_element?(view, "#account-local-clock[data-zone='#{@adelaide}']")

      # The dead render never trusts the browser; a saved zone still applies.
      html = signed_in(conn, saved) |> get(~p"/overview") |> html_response(200)
      assert html =~ ~s(data-zone="#{@london}")
      dead = signed_in(conn, unsaved) |> get(~p"/overview") |> html_response(200)
      assert dead =~ ~s(data-zone="Etc/UTC")
    end

    test "the clock tick refreshes the viewer's current time", %{conn: conn} do
      user = with_zone(user(), @adelaide)
      {:ok, view, _} = live(signed_in(conn, user), ~p"/settings")
      before = clock_time(view)
      send(view.pid, {MarshallWeb.LiveUserAuth, :clock_tick})
      after_tick = clock_time(view)
      assert DateTime.compare(after_tick, before) == :gt
      assert render(element(view, "#profile-local-clock")) =~ ~r/AC[DS]T</
    end

    # @cc [owner:ghuntley,label:security;verification] clock-tick-rechecks-login
    # Revoking the connected page's persisted token MUST make its next clock
    # tick redirect to sign-in; the clock hook MUST NOT consume that tick first.
    test "a clock tick refuses a revoked persisted login", %{conn: conn} do
      user = with_zone(user(), @adelaide)
      conn = signed_in(conn, user)
      token = get_session(conn, "user_token")
      assert {:ok, jti, _} = Marshall.Accounts.Login.verify(token, user)
      {:ok, view, _} = live(conn, ~p"/settings")

      :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
      assert :refused = Marshall.Accounts.Login.token_check(jti, user.id)
      send(view.pid, {MarshallWeb.LiveUserAuth, :clock_tick})

      assert_redirect(view, ~p"/sign-in")
    end
  end

  describe "sign-in and passkeys section" do
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
      {:ok, view, _} = live(conn, "/settings")
      assert has_element?(view, "#verify-passkey")
      assert has_element?(view, "#verification-status", "[not verified]")
      refute has_element?(view, "#verification-status[data-verified]")
      refute has_element?(view, "#security-continue")
      {:ok, %{verified: true}} = Fixture.verify(actor, key)
      send(view.pid, :tick)
      assert has_element?(view, "#security-continue")
      assert has_element?(view, "#verification-status[data-verified]", "[verified]")
    end

    test "passkey verification offers the staged launch without automatic navigation", %{
      conn: conn
    } do
      {actor, token} = Fixture.login(Fixture.user())
      key = Fixture.register(actor)

      {:ok, pending} =
        MarshallWeb.PendingLaunch.new(
          "https://github.com/antithesishq/weaver",
          String.duplicate("a", 32)
        )

      conn =
        signed_in(conn, actor, token) |> put_session(MarshallWeb.PendingLaunch.key(), pending)

      {:ok, view, _} = live(conn, "/settings?return_to=%2Flaunch")
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

    test "launch return requires valid pending input and ignores caller URL variants", %{
      conn: conn
    } do
      actor = Fixture.elevate(Fixture.user())

      for path <- ["/launch", "/launch?source=anything", "//evil.example/launch"] do
        {:ok, view, _} =
          live(
            signed_in(conn, actor, actor.__metadata__.token),
            "/settings?" <> URI.encode_query(%{return_to: path})
          )

        assert has_element?(view, "#security-continue[href='/overview']")
      end
    end

    test "admin reads remain available but a mutation prompts step-up", %{conn: conn} do
      {actor, token} = Fixture.login(Fixture.user(true))
      other = Fixture.user()
      {:ok, view, _} = live(signed_in(conn, actor, token), "/admin/users")
      assert has_element?(view, "#invite-user")
      assert has_element?(view, "a[href='/settings?return_to=%2Fadmin%2Fusers#security']")
      render_click(view, "set-role", %{"id" => other.id, "enabled" => "true"})
      assert_redirect(view, "/settings?return_to=%2Fadmin%2Fusers#security")
      refute Marshall.Accounts.Security.current(other.id).administrator
    end

    test "first enrollment returns to the original page for an explicit retry", %{conn: conn} do
      {actor, token} = Fixture.login(Fixture.user(true))
      target = Fixture.user()
      {:ok, view, _} = live(signed_in(conn, actor, token), "/admin/users")
      render_click(view, "set-role", %{"id" => target.id, "enabled" => "true"})
      assert_redirect(view, "/settings?return_to=%2Fadmin%2Fusers#security")

      {:ok, security, _} =
        live(signed_in(conn, actor, token), "/settings?return_to=%2Fadmin%2Fusers")

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

    test "lock now removes elevation without signing out and unsafe return paths are ignored",
         %{conn: conn} do
      actor = Fixture.elevate(Fixture.user(true))

      {:ok, view, _} =
        live(
          signed_in(conn, actor, actor.__metadata__.token),
          "/settings?return_to=https://evil.example"
        )

      assert has_element?(view, "#security-continue[href='/overview']")
      assert has_element?(view, "#lock-elevation")
      render_click(view, "credential", %{"operation" => "lock"})
      refute has_element?(view, "#lock-elevation")
      assert has_element?(view, "#security-continue")
      assert has_element?(view, "#ssh-key-form")
    end

    test "rename updates the name and remove deletes a passkey through the mounted view", %{
      conn: conn
    } do
      actor = Fixture.elevate(Fixture.user())
      spare = Fixture.register(actor)
      {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings")
      key = passkey_id(actor, actor.__metadata__.test_authenticator)
      spare_id = passkey_id(actor, spare)

      refute has_element?(view, "#passkeys-empty")
      assert has_element?(view, "#passkey-list > div#passkey-#{key} input[value='Test passkey']")
      assert has_element?(view, "#passkey-#{spare_id} input[value='Test passkey']")

      view
      |> form("#label-#{spare_id}")
      |> render_submit(%{"label" => "Backup passkey"})

      assert has_element?(view, "#passkey-#{spare_id} input[value='Backup passkey']")
      assert %{spare_id => "Backup passkey", key => "Test passkey"} == passkeys(actor.id)

      assert has_element?(view, "#remove-#{spare_id}[data-confirm]")
      view |> element("#remove-#{spare_id}") |> render_click()
      refute has_element?(view, "#passkey-#{spare_id}")
      assert %{key => "Test passkey"} == passkeys(actor.id)
      assert has_element?(view, "#verification-status", "Passkey verified")
    end

    test "invalid or unverified credential changes are refused without crashing the view", %{
      conn: conn
    } do
      actor = Fixture.elevate(Fixture.user())
      {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings")
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
      {:ok, view, _} = live(signed_in(conn, actor, actor.__metadata__.token), "/settings")
      [key] = Marshall.Compute.Ledger.read!(Marshall.Accounts.Passkey, user_id: actor.id)

      view |> element("#remove-#{key.id}") |> render_click()
      assert has_element?(view, "#flash-error", "at least one passkey")
      assert %{key.id => "Test passkey"} == passkeys(actor.id)
      assert Marshall.Accounts.Security.current(actor.id).mfa_enabled
    end
  end

  describe "SSH keys section" do
    test "a signed-in user adds, identifies and removes their last public key", %{conn: conn} do
      owner = user()
      {:ok, view, _} = live(signed_in(conn, owner), ~p"/settings")
      assert has_element?(view, "#ssh-keys-empty")
      assert has_element?(view, "#account-index", "0 registered")
      key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 42::256>>)
      view |> form("#ssh-key-form", key: %{label: "Laptop", public_key: key}) |> render_submit()
      assert {:ok, [record]} = SSH.list_keys(%{}, actor: owner)
      assert has_element?(view, "article#ssh-key-#{record.id} h3", "Laptop")
      assert has_element?(view, "#ssh-key-#{record.id} code", record.fingerprint)
      assert has_element?(view, "#ssh-key-#{record.id} time.timestamp[title$='UTC']")
      assert has_element?(view, "#account-index", "1 registered")
      refute has_element?(view, "#ssh-keys-empty")
      assert has_element?(view, "#remove-ssh-key-#{record.id}[data-confirm]")
      view |> element("#remove-ssh-key-#{record.id}") |> render_click()
      assert has_element?(view, "#ssh-keys-empty")
      assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
    end

    test "forged removal cannot revoke another account's key", %{conn: conn} do
      owner = user()
      other = user()
      text = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 43::256>>)
      {:ok, key} = SSH.add_key(%{public_key: text}, actor: owner)
      {:ok, view, _} = live(signed_in(conn, other), ~p"/settings")
      render_click(view, "remove_ssh_key", %{"id" => key.id})
      assert {:ok, [^key]} = SSH.list_keys(%{}, actor: owner)
      assert has_element?(view, "#ssh-keys-empty")
    end

    test "revoked browser login cannot change keys through an existing LiveView", %{conn: conn} do
      owner = user()
      conn = signed_in(conn, owner)
      token = get_session(conn, "user_token")
      {:ok, view, _} = live(conn, ~p"/settings")
      :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
      text = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 44::256>>)
      view |> form("#ssh-key-form", key: %{public_key: text}) |> render_submit()
      assert_redirect(view, ~p"/sign-in")
      assert {:ok, []} = SSH.list_keys(%{}, actor: owner)
    end

    test "accidentally pasted private material is cleared and excluded from debug diagnostics",
         %{conn: conn} do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
      marker = "private-key-sentinel-#{Ash.UUID.generate()}"
      conn = signed_in(conn, user())

      logs =
        capture_log(fn ->
          {:ok, view, _} = live(conn, ~p"/settings")

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

  @spec saved_zone(String.t()) :: String.t() | nil
  defp saved_zone(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
    |> Map.fetch!(:time_zone)
  end

  @spec with_zone(User.t(), String.t()) :: User.t()
  defp with_zone(user, zone), do: Ash.Seed.update!(user, %{time_zone: zone})

  @spec browser(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp browser(conn, zone), do: put_connect_params(conn, %{"timezone" => zone})

  @spec admin_events(String.t()) :: [Marshall.Accounts.AdminEvent.t()]
  defp admin_events(id),
    do: Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent, target_id: id)

  @spec passkeys(String.t()) :: %{String.t() => String.t()}
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
      |> Ash.read!(actor: SystemActor.compute())

    record.id
  end

  @spec clock_time(%Phoenix.LiveViewTest.View{}) :: DateTime.t()
  defp clock_time(view) do
    [instant] =
      view
      |> element("#profile-local-clock")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time")
      |> LazyHTML.attribute("datetime")

    {:ok, time, 0} = DateTime.from_iso8601(instant)
    time
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    signed_in(conn, user, token)
  end

  @spec signed_in(Plug.Conn.t(), User.t(), String.t()) :: Plug.Conn.t()
  defp signed_in(conn, user, token),
    do:
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(
        Ash.Resource.put_metadata(user, :token, token)
      )
end
