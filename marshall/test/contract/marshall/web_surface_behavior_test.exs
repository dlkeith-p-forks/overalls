defmodule MarshallWebSurfaceBehaviorContractTest do
  use Covenant.Case, component: "marshall.web_surface"

  @tag obligation: "marshall.web_surface.I5"
  test "pending launch records require canonical bounded inputs and expire" do
    visit = String.duplicate("a", 32)

    assert {:ok, pending} =
             MarshallWeb.PendingLaunch.new("https://github.com/acme/demo", visit, 1_000)

    assert pending.expires_at == 2_800
    assert %{source: source, visit: ^visit} = MarshallWeb.PendingLaunch.validate(pending, 1_001)
    assert is_binary(source)
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
end
