Code.require_file("../../../scripts/hldd/coverage.ex", __DIR__)
Code.require_file("../../../scripts/hldd/views.ex", __DIR__)
Code.require_file("../../../scripts/hldd/gate.ex", __DIR__)
Code.require_file("../../../scripts/hldd/options.ex", __DIR__)
Code.require_file("hldd_helper.exs", __DIR__)

defmodule Overalls.HLDDTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.{HLDDGate, HLDDCoverage, HLDDOptions}

  setup do
    root =
      Path.join(System.tmp_dir!(), "hldd-test-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @tag :hegel
  test "digests are independent of enumeration order and bind file identities", %{root: root} do
    Hegel.check(
      fn ->
        bytes = draw("bytes", binary())
        name = draw("name", string(:alphanumeric, min_length: 1, max_length: 24))
        write(root, "a", bytes)
        write(root, "b", name)
        assert HLDDGate.digest(root, ["a", "b"]) == HLDDGate.digest(root, ["b", "a"])
        write(root, "c", bytes)
        refute HLDDGate.digest(root, ["a"]) == HLDDGate.digest(root, ["c"])
      end,
      []
    )
  end

  @tag :hegel
  test "edited, added and deleted sources invalidate reviewed receipts", %{root: root} do
    Hegel.check(
      fn ->
        change = draw("change", member_of([:edit, :add, :delete]))
        content = draw("content", binary(min_length: 1))
        fixture(root)
        write(root, "source.ex", "original")

        HLDDGate.record(
          root,
          "system",
          "updated",
          "Initial reviewed handbook and evidence fixture"
        )

        assert HLDDGate.check(root) == []

        case change do
          :edit -> write(root, "source.ex", "changed" <> content)
          :add -> write(root, "new.ex", content)
          :delete -> File.rm!(Path.join(root, "source.ex"))
        end

        assert Enum.any?(HLDDGate.check(root), &String.contains?(&1, "review is stale"))

        HLDDGate.record(
          root,
          "system",
          "no-impact",
          "Fixture mutation preserves the documented public behavior"
        )

        assert HLDDGate.check(root) == []
        File.rm(Path.join(root, "new.ex"))
      end,
      []
    )
  end

  property "traversal and absolute paths never select handbook files" do
    segment = draw("segment", string(:alphanumeric, min_length: 1))
    refute HLDDGate.safe_path?("../" <> segment)
    refute HLDDGate.safe_path?("/" <> segment)
    refute HLDDGate.safe_path?(segment <> "/../../secret")
    assert HLDDGate.safe_path?("source/" <> segment <> ".ex")
  end

  test "devenv and flake pin updates do not enter the reviewed inventory", %{root: root} do
    write(root, "source.ex", "reviewed source")
    write(root, "devenv.lock", "pinned inputs")
    write(root, "flake.lock", "pinned inputs")
    write(root, "devenv.yaml", "inputs")
    write(root, "flake.nix", "inputs")
    assert HLDDGate.files(root) == ["devenv.yaml", "flake.nix", "source.ex"]
  end

  test "CI workflows and scripts do not enter the reviewed inventory", %{root: root} do
    write(root, "source.ex", "reviewed source")
    write(root, ".github/workflows/ci.yml", "workflow")
    write(root, ".github/scripts/select-checks.sh", "script")
    write(root, "nested/.github/kept.ex", "nested source")
    assert HLDDGate.files(root) == ["nested/.github/kept.ex", "source.ex"]
  end

  test "Git and packaged inventories agree on generated history and ignored directories", %{
    root: root
  } do
    write(root, "source.ex", "reviewed source")
    write(root, ".nixos-test-history", "generated execution history")
    write(root, "nested/_build/cache", "generated build output")
    assert HLDDGate.files(root) == ["source.ex"]

    {_, 0} = System.cmd("git", ["init", "--quiet", root])
    {_, 0} = System.cmd("git", ["add", "."], cd: root)
    assert HLDDGate.files(root) == ["source.ex"]
  end

  test "checking never refreshes a receipt and updated requires a chapter edit", %{root: root} do
    fixture(root)
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapter")
    before = File.read!(Path.join(root, "docs/hldd-maintenance.json"))
    write(root, "new.ex", "new code")
    assert HLDDGate.check(root) != []
    assert File.read!(Path.join(root, "docs/hldd-maintenance.json")) == before

    assert_raise RuntimeError, ~r/updated requires/, fn ->
      HLDDGate.record(root, "system", "updated", "Claimed update without a reader-visible change")
    end
  end

  test "missing chapters, unmapped chapters and broken references fail", %{root: root} do
    fixture(root)
    write(root, "marshall/priv/hldd/02-unmapped.md", "# Unmapped\n\n[Missing](repo:missing.ex)\n")
    HLDDGate.record(root, "system", "updated", "Initial fixture covering all known requirements")
    errors = HLDDGate.check(root)
    assert Enum.any?(errors, &String.contains?(&1, "unmapped chapter"))
    assert Enum.any?(errors, &String.contains?(&1, "invalid reference"))
    File.rm!(Path.join(root, "marshall/priv/hldd/01-system.md"))
    assert HLDDGate.check(root) != []
  end

  test "security evidence cannot imply native coverage or recorded execution", %{root: root} do
    data = fixture(root)
    [row] = data["scenarios"]
    assert HLDDCoverage.validate(root, data) == []

    assert HLDDCoverage.validate(root, %{
             data
             | "scenarios" => [%{row | "layers" => ["identity"]}]
           }) != []

    assert HLDDCoverage.validate(root, %{data | "scenarios" => [%{row | "status" => "covered"}]}) !=
             []

    assert HLDDCoverage.validate(root, %{
             data
             | "scenarios" => [%{row | "preferred_gap" => "none"}]
           }) != []

    evidence = %{
      "kind" => "machine",
      "execution" => "recorded",
      "path" => "source.ex",
      "assertion" => "example",
      "scope" => "fixture"
    }

    write(root, "source.ex", "example")

    assert HLDDCoverage.validate(root, %{
             data
             | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]
           }) != []
  end

  test "fresh receipts cannot bypass mandatory visual views", %{root: root} do
    fixture(root)
    path = Path.join(root, "marshall/priv/hldd/21-domains.md")
    File.write!(path, Regex.replace(~r/```mermaid.*?```/s, File.read!(path), ""))
    HLDDGate.record(root, "system", "updated", "Reviewed fixture with removed ownership diagrams")
    errors = HLDDGate.check(root)
    refute Enum.any?(errors, &String.contains?(&1, "review is stale"))
    assert Enum.any?(errors, &String.contains?(&1, "visual inventory is stale"))
  end

  test "Rust Hegel evidence requires its property runner annotation", %{root: root} do
    data = fixture(root)
    [row] = data["scenarios"]

    evidence = %{
      "kind" => "property",
      "execution" => "present",
      "path" => "test.rs",
      "assertion" => "generated_refusal",
      "scope" => "Generated Rust trust input"
    }

    data = %{data | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]}
    write(root, "test.rs", "#[test]\nfn generated_refusal() {}")
    assert Enum.any?(HLDDCoverage.validate(root, data), &String.contains?(&1, "no property test"))

    for attribute <- [
          "#[hegel::test]",
          "#[hegel::test()]",
          "#[hegel::test(test_cases = 8)]",
          "#[hegel::test(test_cases = 4)]",
          "#[hegel::test(hegel::Settings::new(), seed = 42, test_cases = 8,)]",
          "# [ hegel :: test (\n test_cases = 8,\n seed = 42,\n) ]"
        ] do
      write(root, "test.rs", attribute <> "\nfn generated_refusal(tc: TestCase) {}")
      assert HLDDCoverage.validate(root, data) == [], attribute
    end

    for attribute <- [
          "#[hegel::test_not_a_property]",
          "#[hegel::test_not_a_property(test_cases = 8)]",
          "#[other_hegel::test(test_cases = 8)]",
          "#[hegel::test::other]",
          "#[hegel::test = 8]",
          "#[hegel::test{test_cases = 8}]",
          "#[hegel::test[test_cases = 8]]",
          "#[hegel::test(test_cases = 8]",
          "#[hegel::test(test_cases = 8))]",
          "#[hegel::test(test_cases = 8)",
          "[hegel::test(test_cases = 8)]"
        ] do
      write(root, "test.rs", attribute <> "\nfn generated_refusal(tc: TestCase) {}")

      assert HLDDCoverage.validate(root, data) == [
               "property evidence has no property test: test.rs"
             ],
             attribute
    end
  end

  @tag :hegel
  test "configured Hegel evidence preserves assertion and execution requirements", %{
    root: root
  } do
    data = fixture(root)
    [row] = data["scenarios"]

    Hegel.check(
      fn ->
        cases = draw("cases", integer(1..1000))
        whitespace = draw("whitespace", member_of(["", " ", "\n", "\t"]))
        attribute = "#[hegel::test#{whitespace}(test_cases#{whitespace}=#{whitespace}#{cases},)]"
        write(root, "test.rs", attribute <> "\nfn generated_refusal(tc: TestCase) {}")

        evidence = %{
          "kind" => "property",
          "execution" => "present",
          "path" => "test.rs",
          "assertion" => "generated_refusal",
          "scope" => "Generated Rust trust input"
        }

        ledger = fn evidence ->
          %{data | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]}
        end

        assert HLDDCoverage.validate(root, ledger.(evidence)) == []

        assert HLDDCoverage.validate(
                 root,
                 ledger.(%{evidence | "assertion" => "absent_assertion"})
               ) ==
                 ["missing test assertion: test.rs"]

        assert HLDDCoverage.validate(root, ledger.(%{evidence | "path" => "../test.rs"})) ==
                 ["invalid or missing test evidence"]

        assert HLDDCoverage.validate(root, ledger.(%{evidence | "kind" => "machine"})) ==
                 ["machine evidence must reference a NixOS machine test"]

        recorded = Map.put(%{evidence | "execution" => "recorded"}, "record", "result.md")
        recorded = Map.put(recorded, "record_assertion", "configured runner passed")
        write(root, "result.md", "unrelated result")

        assert HLDDCoverage.validate(root, ledger.(recorded)) ==
                 ["recorded execution needs an existing scoped result"]

        write(root, "result.md", "configured runner passed")
        assert HLDDCoverage.validate(root, ledger.(recorded)) == []
      end,
      []
    )
  end

  test "explicit Elixir Hegel runners and parenthesized properties preserve evidence checks", %{
    root: root
  } do
    data = fixture(root)
    [row] = data["scenarios"]

    evidence = %{
      "kind" => "property",
      "execution" => "present",
      "path" => "test.exs",
      "assertion" => "generated_refusal",
      "scope" => "Explicit native Elixir runner recognition only"
    }

    ledger = %{data | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]}

    for runner <- [
          "Hegel.check(",
          "Hegel.run(",
          "Hegel . check (",
          "Hegel.\nrun(",
          "property(",
          "property\n(",
          "# A preceding contract sentence.\nproperty(",
          "defmodule Example do\n  property ("
        ] do
      write(root, "test.exs", runner <> "fn test_case -> generated_refusal(test_case) end)")
      assert HLDDCoverage.validate(root, ledger) == [], runner

      absent = %{evidence | "assertion" => "absent_assertion"}

      assert HLDDCoverage.validate(root, %{
               ledger
               | "scenarios" => [%{row | "evidence" => [absent], "status" => "partial"}]
             }) == ["missing test assertion: test.exs"]
    end

    for runner <- [
          "OtherHegel.check(",
          "Other.Hegel.check(",
          "Other . Hegel.check(",
          "Hegel.check_not_a_runner(",
          "Hegel.check_run_not_a_runner(",
          "Hegel.check",
          "@tag :hegel",
          "not_property(",
          "Other.property(",
          "Other. property(",
          "Other . property (",
          "Other.\nproperty (",
          "property_not_a_runner("
        ] do
      write(root, "test.exs", runner <> " generated_refusal")

      assert HLDDCoverage.validate(root, ledger) == [
               "property evidence has no property test: test.exs"
             ],
             runner
    end
  end

  test "existing non-Hegel property runner markers remain recognized", %{root: root} do
    data = fixture(root)
    [row] = data["scenarios"]

    for marker <- ["property ", "check all", "proptest!", "@given"] do
      write(root, "test.source", marker <> " generated_refusal")

      evidence = %{
        "kind" => "property",
        "execution" => "present",
        "path" => "test.source",
        "assertion" => "generated_refusal",
        "scope" => "Existing property runner recognition"
      }

      assert HLDDCoverage.validate(root, %{
               data
               | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]
             }) == []
    end
  end

  test "explicit Hegel callbacks qualify without accepting function name prefixes", %{root: root} do
    data = fixture(root)
    [row] = data["scenarios"]

    for {runner, valid?} <- [
          {"Hegel.check(fn test_case -> generated_refusal end)", true},
          {"Hegel.check(\n fn test_case -> generated_refusal end)", true},
          {"Hegel.check_other(fn test_case -> generated_refusal end)", false},
          {"OtherHegel.check(fn test_case -> generated_refusal end)", false}
        ] do
      write(root, "test.exs", runner)

      evidence = %{
        "kind" => "property",
        "execution" => "present",
        "path" => "test.exs",
        "assertion" => "generated_refusal",
        "scope" => "Explicit callback runner recognition"
      }

      errors =
        HLDDCoverage.validate(root, %{
          data
          | "scenarios" => [%{row | "evidence" => [evidence], "status" => "partial"}]
        })

      assert errors == [] == valid?
    end
  end

  test "options retain required fields and normalize build-specific store hashes" do
    option = %{
      "name" => "services.example.keyFile",
      "type" => "string",
      "description" => "Private file.",
      "default" => nil,
      "example" => nil
    }

    assert HLDDOptions.render(JSON.encode!([option])) =~ "Required when its service"

    option = %{
      option
      | "default" => %{"text" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package"}
    }

    result = HLDDOptions.render(JSON.encode!([option]))
    assert result =~ "<store>/package"
    refute result =~ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    assert_raise RuntimeError, fn -> HLDDOptions.render("[{}]") end
  end

  @spec write(String.t(), String.t(), String.t()) :: :ok
  defp write(root, path, content) do
    target = Path.join(root, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
  end

  @spec fixture(String.t()) :: map()
  defp fixture(root) do
    File.rm_rf!(root)

    data = %{
      "version" => 1,
      "scenarios" => [
        %{
          "id" => "recovery",
          "journey" => "Recover safely",
          "boundary" => "Current authority",
          "denial" => "Reject stale restored authority",
          "scope" => "No executed evidence",
          "layers" => ~w(identity authorization transport execution isolation storage recovery),
          "status" => "gap",
          "gaps" => "No complete recovery test",
          "preferred_gap" => "Add native recovery and generated authority histories",
          "evidence" => []
        }
      ]
    }

    write(root, "marshall/priv/hldd/scenarios.json", JSON.encode!(data))
    write(root, "marshall/priv/hldd/19-coverage.md", HLDDCoverage.render(data))
    write(root, "marshall/priv/hldd/01-system.md", "# System\n\nReviewed behavior.\n")
    Overalls.HLDDViewFixture.fixture(root)

    write(
      root,
      "docs/hldd-maintenance.json",
      JSON.encode!(%{
        "version" => 1,
        "groups" => [
          %{
            "id" => "system",
            "prefixes" => [],
            "chapters" => ["01-system.md", "19-coverage.md", "21-domains.md", "22-topology.md"]
          }
        ]
      })
    )

    data
  end
end
