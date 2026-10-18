Code.require_file("../../../scripts/dependency_pins.ex", __DIR__)
Code.require_file("../../../scripts/mix_security_upgrades.ex", __DIR__)

defmodule Overalls.MixSecurityUpgradesTest do
  use ExUnit.Case, async: true
  alias Overalls.{DependencyPins, MixSecurityUpgrades}
  alias Overalls.DependencyPins.Finding

  # Captured from Hex 2.5.3 `mix hex.audit` for plug 1.3.0, with a retired
  # section and an ignored advisory added to cover the other report shapes.
  @audit """
  Advisories:
    plug 1.3.0 - GHSA-2q6v-32mr-8p8x (HIGH)
      aka: CVE-2017-1000052
      Null Byte Injection in Plug.Static
      https://osv.dev/vulnerability/GHSA-2q6v-32mr-8p8x

    plug 1.3.0 - EEF-CVE-2026-56813 (LOW)
      aka: CVE-2026-56813, GHSA-wpmj-jh88-rpgm
      Cookie attribute injection in Plug.Conn.Cookies.encode/2
      https://osv.dev/vulnerability/EEF-CVE-2026-56813

  Retired:
    \e[1mDependency  Version  Retirement reason\e[0m
    decimal     1.0.0    (deprecated) Use 2.x
    cowboy      2.9.0    (security) Upgrade to 2.10.0

  Ignored advisories:
    mime 1.1.0 - GHSA-0000-0000-0000 (HIGH)
      Ignored by configuration

  Found packages with security advisories
  """

  # @cc [owner:ghuntley,label:verification;security] mix-security-upgrades-audit-oracle
  # Only unignored advisories and security retirements are update candidates;
  # deprecated retirements and ignored advisories MUST NOT be updated.
  test "keeps advisories and security retirements only" do
    assert [
             %Finding{
               kind: :advisory,
               package: "plug",
               id: "GHSA-2q6v-32mr-8p8x",
               severity: "HIGH",
               summary: "Null Byte Injection in Plug.Static"
             },
             %Finding{
               kind: :advisory,
               package: "plug",
               id: "EEF-CVE-2026-56813",
               severity: "LOW"
             },
             %Finding{
               kind: :retirement,
               package: "cowboy",
               version: "2.9.0",
               summary: "Upgrade to 2.10.0"
             }
           ] = findings = MixSecurityUpgrades.parse_audit(@audit)

    assert DependencyPins.packages(findings) == ["cowboy", "plug"]
  end

  test "reports nothing for a clean audit" do
    assert MixSecurityUpgrades.parse_audit("No retired or security advisory packages found\n") ==
             []
  end

  test "requires a Hex archive that reports advisories" do
    assert MixSecurityUpgrades.supported_hex?("Hex:    2.5.3\nElixir: 1.20.4\n")
    refute MixSecurityUpgrades.supported_hex?("Hex:    2.4.0\n")
    refute MixSecurityUpgrades.supported_hex?("")
  end

  test "discovers lock-file projects outside fetched dependencies" do
    projects = MixSecurityUpgrades.projects(Path.expand("../../..", __DIR__))
    assert "marshall" in projects and "protocol" in projects and "elixir/diagnostics" in projects
    refute Enum.any?(projects, &String.contains?(&1, "deps/"))
  end
end
