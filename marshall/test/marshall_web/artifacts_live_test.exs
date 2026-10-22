defmodule MarshallWeb.ArtifactsLiveTest do
  # @cc [owner:ghuntley,label:verification;security] artifacts-live-authorized-views
  # The artifacts LiveView MUST list only Cedar-readable artifacts, render the
  # viewer as a sandboxed credentialless iframe on the content origin, expose
  # sharing only to owners, and enforce storage roles through the bridge event.
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures

  alias Marshall.Artifacts.{Publisher, Sharing}

  setup do
    previous = Application.get_env(:marshall, :artifact_content)

    Application.put_env(:marshall, :artifact_content, %{
      host: "usercontent.test",
      debug_echo: false
    })

    on_exit(fn ->
      # Restoring an absent key as nil would leak into later peer nodes.
      if previous == nil,
        do: Application.delete_env(:marshall, :artifact_content),
        else: Application.put_env(:marshall, :artifact_content, previous)
    end)

    %{owner: user(), viewer: user(), stranger: user()}
  end

  @spec publish!(Marshall.Accounts.User.t(), String.t()) :: Marshall.Artifacts.Artifact.t()
  defp publish!(owner, title) do
    {:ok, %{artifact: artifact}} =
      Publisher.publish(owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "<!doctype html><p>#{title}</p>"},
        title: title,
        via: :web
      })

    artifact
  end

  @spec share!(
          Marshall.Accounts.User.t(),
          Marshall.Artifacts.Artifact.t(),
          Marshall.Accounts.User.t(),
          atom()
        ) :: :ok
  defp share!(owner, artifact, user, role) do
    {:ok, _} =
      Sharing.set_access(
        owner,
        artifact.id,
        {:email, to_string(user.email)},
        role,
        Ash.UUID.generate()
      )

    :ok
  end

  test "the index lists only readable artifacts", c do
    mine = publish!(c.owner, "Owner report")
    _other = publish!(c.stranger, "Stranger report")

    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/artifacts")
    assert has_element?(view, "#artifacts-list", "Owner report")
    refute has_element?(view, "#artifacts-list", "Stranger report")
    assert has_element?(view, "a[href='/artifacts/#{mine.id}']")
  end

  test "the viewer is a sandboxed iframe on the content origin", c do
    artifact = publish!(c.owner, "Framed")
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/artifacts/#{artifact.id}")

    frame = view |> element("#artifact-frame") |> render()
    assert frame =~ ~s(sandbox="allow-scripts")
    assert frame =~ ~s(referrerpolicy="no-referrer")
    assert frame =~ "credentialless"
    assert frame =~ ~r|src="https://usercontent\.test/v/[A-Za-z0-9_-]{43}/"|
    refute frame =~ "allow-same-origin"
  end

  test "strangers cannot open an artifact and viewers cannot share it", c do
    artifact = publish!(c.owner, "Private")

    assert {:error, {_, %{to: "/artifacts"}}} =
             live(signed_in(c.conn, c.stranger), ~p"/artifacts/#{artifact.id}")

    share!(c.owner, artifact, c.viewer, :viewer)
    {:ok, view, _html} = live(signed_in(c.conn, c.viewer), ~p"/artifacts/#{artifact.id}/sharing")
    refute has_element?(view, "#artifact-sharing")
    refute has_element?(view, "#artifact-delete")
  end

  test "owners share and revoke through the sharing view", c do
    artifact = publish!(c.owner, "Shared")
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/artifacts/#{artifact.id}/sharing")

    view
    |> form("#artifact-share-form", access: %{email: to_string(c.viewer.email), role: "viewer"})
    |> render_submit()

    assert has_element?(view, "#artifact-grants", to_string(c.viewer.email))
    assert {:ok, _, _} = live(signed_in(build_conn(), c.viewer), ~p"/artifacts/#{artifact.id}")
  end

  test "the storage bridge enforces roles and namespaces", c do
    artifact = publish!(c.owner, "Storage")
    share!(c.owner, artifact, c.viewer, :viewer)
    {:ok, owner_view, _} = live(signed_in(c.conn, c.owner), ~p"/artifacts/#{artifact.id}")
    {:ok, viewer_view, _} = live(signed_in(build_conn(), c.viewer), ~p"/artifacts/#{artifact.id}")

    assert render_hook(owner_view, "storage", %{
             "op" => "set",
             "namespace" => "shared",
             "key" => "k",
             "value" => "v"
           })

    assert_reply(owner_view, %{ok: true})

    render_hook(viewer_view, "storage", %{
      "op" => "set",
      "namespace" => "shared",
      "key" => "k",
      "value" => "x"
    })

    assert_reply(viewer_view, %{ok: false})

    render_hook(viewer_view, "storage", %{"op" => "get", "namespace" => "shared", "key" => "k"})
    assert_reply(viewer_view, %{ok: true, value: "v"})

    render_hook(viewer_view, "storage", %{
      "op" => "set",
      "namespace" => "personal",
      "key" => "k",
      "value" => "mine"
    })

    assert_reply(viewer_view, %{ok: true})

    render_hook(owner_view, "storage", %{"op" => "get", "namespace" => "personal", "key" => "k"})
    assert_reply(owner_view, %{ok: true, value: nil})

    render_hook(viewer_view, "storage", %{"op" => "drop", "namespace" => "shared"})
    assert_reply(viewer_view, %{ok: false, error: "invalid_request"})
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
