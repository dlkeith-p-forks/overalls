defmodule MarshallWeb.AuthenticationPrivacyTest do
  use MarshallWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  test "magic-link request paths and LiveView diagnostics do not expose the link", %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    marker = "credential-marker-#{Ash.UUID.generate()}"

    logs =
      capture_log(fn ->
        {:ok, view, _} = live(conn, "/magic_link/" <> marker)
        # The connected process keeps the privacy tag throughout later events.
        dictionary = Process.info(view.pid, :dictionary) |> elem(1)
        logger = Keyword.get(dictionary, :"$logger_metadata$")
        assert logger[:marshall_authentication]
      end)

    hidden? = not String.contains?(logs, marker)
    assert hidden?
    assert logs =~ "Authentication process diagnostic"
  end

  test "malformed captured repository credentials stay out of HTTP diagnostics", %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    marker = "captured-secret-#{Ash.UUID.generate()}"

    logs =
      capture_log(fn ->
        response =
          post(conn, "/launch/pending", %{
            "source" => "https://" <> marker <> "@github.com/owner/repository",
            "visit" => String.duplicate("a", 32)
          })

        assert response.status == 422
        refute response.resp_body =~ marker
        refute get_session(response, MarshallWeb.PendingLaunch.key())
      end)

    refute logs =~ marker
    assert logs =~ "Authentication process diagnostic"
  end
end
