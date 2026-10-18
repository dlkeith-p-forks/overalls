defmodule MarshallWeb.TimeComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias MarshallWeb.TimeComponents

  @instant ~U[2026-10-18 09:12:07.000000Z]

  defp fragment(html), do: LazyHTML.from_fragment(html)

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

  test "timestamp renders in the zone with the UTC instant as provenance" do
    doc =
      fragment(
        render_component(&TimeComponents.timestamp/1,
          at: @instant,
          zone: "Australia/Adelaide",
          id: "t"
        )
      )

    assert text(doc, "time#t") == "2026-10-18 19:42 ACDT"
    assert attribute(doc, "time#t", "datetime") == "2026-10-18T09:12:07.000000Z"
    assert attribute(doc, "time#t", "title") == "2026-10-18 09:12:07 UTC"
    assert attribute(doc, "time#t", "data-zone") == "Australia/Adelaide"
  end

  test "timestamp formats and falls back to UTC for nil or unknown zones" do
    render = fn zone, format ->
      render_component(&TimeComponents.timestamp/1, at: @instant, zone: zone, format: format)
      |> fragment()
      |> text("time")
    end

    assert render.(nil, :datetime) == "2026-10-18 09:12 UTC"
    assert render.("Mars/Olympus", :datetime_seconds) == "2026-10-18 09:12:07 UTC"
    assert render.("Asia/Kathmandu", :date) == "2026-10-18"
    assert render.("Asia/Kathmandu", :time) == "14:57 +0545"
    assert render.("America/New_York", :clock) == "5:12 AM EDT"
    assert render.("Pacific/Chatham", :day_month) == "18 Oct"

    assert render_component(&TimeComponents.timestamp/1, at: nil, zone: "Etc/UTC")
           |> fragment()
           |> text("span") == "—"
  end

  test "person shows local time only for a saved zone" do
    saved =
      fragment(
        render_component(&TimeComponents.person/1,
          email: "hana@example.test",
          time_zone: "Australia/Adelaide",
          viewer_zone: "Europe/London",
          now: @instant,
          id: "p"
        )
      )

    assert text(saved, "#p .person-email") == "hana@example.test"
    assert text(saved, "#p .local-time") == "7:42 PM ACDT local time · 9h 30m ahead of you"
    assert attribute(saved, "#p .local-time", "data-zone") == "Australia/Adelaide"

    unsaved =
      fragment(
        render_component(&TimeComponents.person/1,
          email: "momo@example.test",
          time_zone: nil,
          viewer_zone: "Australia/Adelaide",
          now: @instant,
          id: "q"
        )
      )

    assert text(unsaved, "#q") == "momo@example.test"
    assert LazyHTML.query(unsaved, "#q .local-time") |> Enum.empty?()
  end

  test "person text follows the sign of the difference" do
    render = fn viewer, other ->
      render_component(&TimeComponents.local_time/1,
        zone: other,
        viewer_zone: viewer,
        now: @instant
      )
      |> fragment()
      |> text(".local-time")
    end

    assert render.("Australia/Adelaide", "Europe/London") =~ "9h 30m behind you"
    assert render.("Europe/London", "Europe/London") =~ "same time as you"
    assert render.("Europe/London", "Europe/Paris") =~ "1h ahead of you"
    assert render.("Asia/Kolkata", "Asia/Kathmandu") =~ "15m ahead of you"
  end

  test "local clock names the viewer's zone and source" do
    doc =
      fragment(
        render_component(&TimeComponents.local_clock/1,
          zone: "Asia/Tokyo",
          now: @instant,
          source: :browser
        )
      )

    assert text(doc, "#local-clock") == "6:12 PM JST"
    assert attribute(doc, "#local-clock", "data-zone-source") == "browser"
    assert attribute(doc, "#local-clock", "title") == "Asia/Tokyo · 2026-10-18 09:12:07 UTC"
  end
end
