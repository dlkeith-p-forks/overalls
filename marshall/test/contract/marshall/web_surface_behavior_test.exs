defmodule MarshallWebSurfaceBehaviorContractTest do
  use Covenant.Case, component: "marshall.web_surface"

  @tag obligation: "marshall.web_surface.I5"
  test "pending launch records require canonical bounded inputs and expire" do
    visit = String.duplicate("a", 32)

    assert {:ok, pending} =
             MarshallWeb.PendingLaunch.new("https://github.com/acme/demo", visit, 1_000)

    assert pending.expires_at == 2_800
    assert %{source: source, visit: ^visit} = MarshallWeb.PendingLaunch.validate(pending, 1_001)

    assert source == %{
             provider: :github,
             namespace: ["acme"],
             repository: "demo",
             revision: %{kind: :default}
           }

    assert OverallsProtocol.WorkspaceSource.to_url(source) == pending.source
    assert MarshallWeb.PendingLaunch.validate(pending, 2_800) == nil

    assert MarshallWeb.PendingLaunch.validate(
             %{source: pending.source, visit: visit, expires_at: 9_999},
             1_000
           ) == nil

    assert {:error, :invalid_visit} = MarshallWeb.PendingLaunch.new(pending.source, "bad", 1_000)
  end

  @tag obligation: "marshall.web_surface.I6"
  test "terminal names are deterministic and vocabulary bounded" do
    first = MarshallWeb.TerminalNames.display_name("session-1")
    assert first == MarshallWeb.TerminalNames.display_name("session-1")
    assert Regex.match?(~r/\A[a-z]+-[a-z]+\z/, first)
    refute first =~ " "
  end

  @tag obligation: "marshall.web_surface.I9"
  test "converted timestamps keep the UTC instant and people show saved zones only" do
    import Phoenix.LiveViewTest
    instant = ~U[2026-10-18 09:12:07Z]

    html =
      render_component(&MarshallWeb.TimeComponents.timestamp/1,
        at: instant,
        zone: "Australia/Adelaide"
      )

    assert html =~ ~s(datetime="2026-10-18T09:12:07Z")
    assert html =~ ~s(title="2026-10-18 09:12:07 UTC")
    assert html =~ "2026-10-18 19:42 ACDT"

    saved =
      render_component(&MarshallWeb.TimeComponents.person/1,
        email: "hana@example.test",
        time_zone: "Australia/Adelaide",
        viewer_zone: "Europe/London",
        now: instant
      )

    assert saved =~ "7:42 PM ACDT local time · 9h 30m ahead of you"

    unsaved =
      render_component(&MarshallWeb.TimeComponents.person/1,
        email: "momo@example.test",
        time_zone: nil,
        viewer_zone: "Europe/London",
        now: instant
      )

    refute unsaved =~ "local time"
    assert unsaved =~ "momo@example.test"
  end
end
