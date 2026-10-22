defmodule MarshallWeb.ArtifactContentEndpointTest do
  # @cc [owner:ghuntley,label:security;verification] artifact-content-endpoint-lockdown
  # Every content response, including refusals and unknown routes, MUST carry
  # the exact lockdown header set and no set-cookie; only GET/HEAD on a valid
  # ticket for the configured host serve content; Markdown raw HTML is escaped;
  # disallowed media types are attachments; revocation stops a live ticket.
  use Marshall.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Marshall.Artifacts.{Publisher, Sharing, Tickets}
  alias MarshallWeb.{ArtifactContentEndpoint, ArtifactContentHeaders}

  @host "usercontent.test"

  setup do
    previous = Application.get_env(:marshall, :artifact_content)
    Application.put_env(:marshall, :artifact_content, %{host: @host, debug_echo: false})

    on_exit(fn ->
      # Restoring an absent key as nil would leak into later peer nodes.
      if previous == nil,
        do: Application.delete_env(:marshall, :artifact_content),
        else: Application.put_env(:marshall, :artifact_content, previous)
    end)

    owner = Marshall.PasskeyFixture.user(false)
    %{owner: owner}
  end

  @spec publish!(Marshall.Accounts.User.t(), map()) :: Publisher.published()
  defp publish!(owner, overrides \\ %{}) do
    {:ok, published} =
      Publisher.publish(
        owner,
        Map.merge(
          %{
            artifact_id: nil,
            base_version: 0,
            page: {:content, "<!doctype html><p>hi</p>"},
            via: :web
          },
          overrides
        )
      )

    published
  end

  @spec ticket!(Marshall.Accounts.User.t(), Publisher.published()) :: String.t()
  defp ticket!(user, %{artifact: artifact, version: version}) do
    {:ok, token} = Tickets.issue(user, artifact, version, @host)
    token
  end

  @spec call(String.t(), String.t(), String.t()) :: Plug.Conn.t()
  defp call(method, path, host \\ @host) do
    conn(method, path)
    |> Map.put(:host, host)
    |> put_req_header("cookie", "__Host-marshall=secret")
    |> ArtifactContentEndpoint.call(ArtifactContentEndpoint.init([]))
  end

  @spec assert_lockdown!(Plug.Conn.t()) :: :ok
  defp assert_lockdown!(conn) do
    for {name, value} <- ArtifactContentHeaders.headers(@host, marshall_host()) do
      assert get_resp_header(conn, name) == [value], "#{name} missing or changed"
    end

    assert get_resp_header(conn, "set-cookie") == []
    assert get_resp_header(conn, "x-frame-options") == []
    :ok
  end

  defp marshall_host, do: MarshallWeb.Endpoint.config(:url)[:host] || "localhost"

  test "a valid ticket serves the page with the helper after the doctype", %{owner: owner} do
    published = publish!(owner)
    conn = call("GET", "/v/#{ticket!(owner, published)}/")

    assert conn.status == 200
    assert_lockdown!(conn)
    assert conn.resp_body =~ ~r/\A<!doctype html><script>/
    assert conn.resp_body =~ "<p>hi</p>"
  end

  test "refusals and unknown routes are locked-down 404s without cookies", %{owner: owner} do
    published = publish!(owner)
    token = ticket!(owner, published)

    for conn <- [
          call("GET", "/"),
          call("GET", "/health"),
          call("GET", "/v/not-a-ticket/"),
          call("GET", "/v/" <> String.duplicate("A", 43) <> "/"),
          call("POST", "/v/#{token}/"),
          call("DELETE", "/v/#{token}/"),
          call("GET", "/v/#{token}/", "marshall.test"),
          call("GET", "/v/#{token}/missing.css"),
          call("GET", "/v/#{token}/__echo")
        ] do
      assert conn.status == 404
      assert_lockdown!(conn)
    end
  end

  test "a stranger's and a revoked viewer's tickets are refused", %{owner: owner} do
    published = publish!(owner)
    viewer = Marshall.PasskeyFixture.user(false)
    stranger = Marshall.PasskeyFixture.user(false)

    assert {:error, :not_found} =
             Tickets.issue(stranger, published.artifact, published.version, @host)

    {:ok, _} =
      Sharing.set_access(
        owner,
        published.artifact.id,
        {:email, to_string(viewer.email)},
        :viewer,
        Ash.UUID.generate()
      )

    token = ticket!(viewer, published)
    assert call("GET", "/v/#{token}/").status == 200

    {:ok, _} =
      Sharing.set_access(
        owner,
        published.artifact.id,
        {:email, to_string(viewer.email)},
        :revoked,
        Ash.UUID.generate()
      )

    conn = call("GET", "/v/#{token}/")
    assert conn.status == 404
    assert_lockdown!(conn)
  end

  test "markdown raw HTML is escaped and unknown media types are attachments", %{owner: owner} do
    published =
      publish!(owner, %{
        format: :markdown,
        title: "Notes",
        page: {:content, "# Title\n\n<script>alert(1)</script>"},
        files: %{"data.bin" => {:bytes, "abc", nil}, "style.css" => {:bytes, "p{}", nil}}
      })

    token = ticket!(owner, published)
    page = call("GET", "/v/#{token}/")
    assert page.status == 200
    refute page.resp_body =~ "<script>alert(1)</script>"
    assert page.resp_body =~ "&lt;script&gt;"

    binary = call("GET", "/v/#{token}/data.bin")
    assert binary.status == 200
    assert get_resp_header(binary, "content-type") |> hd() =~ "application/octet-stream"
    assert get_resp_header(binary, "content-disposition") == ["attachment"]
    assert_lockdown!(binary)

    css = call("GET", "/v/#{token}/style.css")
    assert get_resp_header(css, "content-type") |> hd() =~ "text/css"
    assert get_resp_header(css, "content-disposition") == []
  end

  test "the echo probe is served only when explicitly enabled for tests", %{owner: owner} do
    Application.put_env(:marshall, :artifact_content, %{host: @host, debug_echo: true})
    token = ticket!(owner, publish!(owner))
    conn = call("GET", "/v/#{token}/__echo")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"cookie" => true, "authorization" => false}
  end
end
