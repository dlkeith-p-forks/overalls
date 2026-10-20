Code.require_file("../../../scripts/hldd/coverage.ex", __DIR__)
Code.require_file("../../../scripts/hldd/views.ex", __DIR__)
Code.require_file("../../../scripts/hldd/gate.ex", __DIR__)
Code.require_file("../../../scripts/hldd/migration.ex", __DIR__)
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
  @tag timeout: 180_000
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
    receipt = Path.join(root, HLDDGate.receipt_path("source", "example/lib/domain.ex"))
    before = File.read!(receipt)
    write(root, "new.ex", "new code")
    assert HLDDGate.check(root) != []
    assert File.read!(receipt) == before

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

  test "independent reviews in the same group merge without recording again", %{root: root} do
    fixture(root)
    write(root, "left.ex", "left base")
    write(root, "right.ex", "right base")
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    git(root, ["init", "-q", "-b", "trunk"])
    git(root, ["config", "user.name", "HLDD Fixture"])
    git(root, ["config", "user.email", "hldd@example.invalid"])
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "base"])
    git(root, ["checkout", "-qb", "left"])
    write(root, "left.ex", "left independently reviewed")

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Left source preserves the documented fixture behavior",
      ["left.ex"]
    )

    git(root, ["add", "."])
    git(root, ["commit", "-qm", "left review"])
    git(root, ["checkout", "-q", "trunk"])
    write(root, "right.ex", "right independently reviewed")

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Right source preserves the documented fixture behavior",
      ["right.ex"]
    )

    git(root, ["add", "."])
    git(root, ["commit", "-qm", "right review"])
    git(root, ["merge", "--no-edit", "left"])
    assert HLDDGate.check(root) == []
    assert git(root, ["status", "--porcelain"]) == ""
  end

  test "chapter review does not rewrite source receipts and selected records leave other work stale",
       %{root: root} do
    fixture(root)
    write(root, "left.ex", "original")
    write(root, "right.ex", "original")
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    source = Path.join(root, HLDDGate.receipt_path("source", "left.ex"))
    original = File.read!(source)
    chapter = "marshall/priv/hldd/01-system.md"
    write(root, chapter, "# System\n\nReviewed clarified documentation.\n")
    assert [%{path: ^chapter}] = stale(root)

    HLDDGate.record(
      root,
      "system",
      "updated",
      "Clarified the fixture chapter without changing source behavior",
      [chapter]
    )

    assert File.read!(source) == original
    assert HLDDGate.check(root) == []
    write(root, "left.ex", "left change")
    write(root, "right.ex", "right change")

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Left change preserves the fixture's documented behavior",
      ["left.ex"]
    )

    assert [%{path: "right.ex"}] = stale(root)
    assert File.read!(source) != original
    reviewed = File.read!(source)

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Repeated review must leave current receipts untouched",
      ["left.ex"]
    )

    assert File.read!(source) == reviewed
    write(root, "left.ex", "combined merge content that neither side reviewed")
    assert Enum.any?(stale(root), &(&1.path == "left.ex"))
  end

  test "deletions need tombstones and restoring or renaming a source needs new review", %{
    root: root
  } do
    fixture(root)
    write(root, "before.ex", "original")
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    File.rename!(Path.join(root, "before.ex"), Path.join(root, "after.ex"))

    assert Enum.map(stale(root), &{&1.path, &1.status}) == [
             {"after.ex", "added"},
             {"before.ex", "deleted"}
           ]

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Renamed the fixture source without changing documented behavior"
    )

    assert HLDDGate.check(root) == []
    write(root, "before.ex", "original")
    assert [%{path: "before.ex", status: "restored"}] = stale(root)
  end

  test "updated can cite a chapter already reviewed since the source's previous review", %{
    root: root
  } do
    fixture(root)
    write(root, "source.ex", "original")
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    chapter = "marshall/priv/hldd/01-system.md"
    write(root, chapter, "# System\n\nChanged documented behavior.\n")

    HLDDGate.record(root, "system", "updated", "Reviewed the changed chapter independently", [
      chapter
    ])

    receipt = Path.join(root, HLDDGate.receipt_path("chapter", chapter))
    reviewed = File.read!(receipt)
    write(root, "source.ex", "implementation of changed behavior")

    HLDDGate.record(
      root,
      "system",
      "updated",
      "Source implements the already reviewed chapter change",
      ["source.ex", chapter]
    )

    assert File.read!(receipt) == reviewed
    assert HLDDGate.check(root) == []
    write(root, "source.ex", "another source change without a chapter edit")

    assert_raise RuntimeError, ~r/updated requires/, fn ->
      HLDDGate.record(
        root,
        "system",
        "updated",
        "Cannot reuse the same old documentation change twice",
        ["source.ex", chapter]
      )
    end
  end

  test "reviewed tombstones cannot hide missing mapped chapters or restored legacy ledgers", %{
    root: root
  } do
    fixture(root)
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    chapter = "marshall/priv/hldd/01-system.md"
    File.rm!(Path.join(root, chapter))

    HLDDGate.record(
      root,
      "system",
      "no-impact",
      "Even explicit review cannot remove a still mapped chapter",
      [chapter]
    )

    assert Enum.any?(HLDDGate.check(root), &String.contains?(&1, "missing mapped chapter"))
    fixture(root)
    write(root, "marshall/priv/hldd/scenarios.json", "{}")
    assert_raise RuntimeError, ~r/legacy scenarios/, fn -> HLDDCoverage.read(root) end
    File.rm!(Path.join(root, "marshall/priv/hldd/scenarios.json"))
    write(root, "marshall/priv/hldd/deployment-topology.json", "[]")

    assert Overalls.HLDDViews.check(root, HLDDGate.files(root)) == [
             "legacy deployment-topology.json exists; regenerate topology YAML instead"
           ]
  end

  test "mapping changes invalidate only sources whose associations changed", %{root: root} do
    fixture(root)
    write(root, "owned/file.ex", "original")
    write(root, "unrelated.ex", "original")
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")

    Overalls.HLDDDocuments.write([
      %{
        "path" => Path.join(root, "docs/hldd/groups/owned.yaml"),
        "data" => %{"id" => "owned", "prefixes" => ["owned/"], "chapters" => ["01-system.md"]}
      }
    ])

    assert Enum.any?(
             stale(root),
             &(&1.path == "owned/file.ex" and &1.status == "mapping-changed")
           )

    refute Enum.any?(stale(root), &(&1.path == "unrelated.ex"))
  end

  test "malformed YAML, duplicate keys and receipt path substitution fail closed", %{root: root} do
    fixture(root)
    HLDDGate.record(root, "system", "updated", "Initial reviewed fixture and complete chapters")
    receipt = Path.join(root, HLDDGate.receipt_path("source", "example/lib/domain.ex"))
    original = File.read!(receipt)

    for invalid <- [
          "---\nversion: 2\nversion: 2\n---\nreview rationale long enough",
          "---\nvalue: &value x\ncopy: *value\n---\nreview rationale long enough",
          "---\nvalue: !custom tag\n---\nreview rationale long enough"
        ] do
      File.write!(receipt, invalid)
      assert HLDDGate.check(root) != []
    end

    File.write!(
      receipt,
      String.replace(original, "path: example/lib/domain.ex", "path: ../outside.ex")
    )

    assert HLDDGate.check(root) != []
    File.write!(receipt, original)
    assert HLDDGate.check(root) == []
    File.rm!(receipt)
    assert Enum.any?(stale(root), &(&1.path == "example/lib/domain.ex"))
  end

  test "migration rejects stale legacy evidence before writing and preserves baseline hashes", %{
    root: root
  } do
    fixture(root)
    write(root, "source.ex", "baseline")
    groups = HLDDGate.manifest(root)["groups"]
    File.rm_rf!(Path.join(root, "docs/hldd/groups"))

    groups =
      Enum.map(groups, fn group ->
        Map.merge(group, %{
          "source_digest" =>
            HLDDGate.digest(root, HLDDGate.assigned(HLDDGate.files(root), groups, group)),
          "chapter_digest" =>
            HLDDGate.digest(
              root,
              Enum.map(group["chapters"], &Path.join("marshall/priv/hldd", &1))
            ),
          "disposition" => "no-impact",
          "rationale" => "Legacy reviewed fixture preserves the described behavior"
        })
      end)

    write(root, "docs/hldd-maintenance.json", JSON.encode!(%{"version" => 1, "groups" => groups}))
    target = root <> "-target"
    on_exit(fn -> File.rm_rf!(target) end)
    write(root, "source.ex", "unreviewed")

    assert_raise RuntimeError, ~r/stale legacy group/, fn ->
      Overalls.HLDDMigration.run(target, root)
    end

    refute File.exists?(Path.join(target, "docs/hldd/reviews"))
    write(root, "source.ex", "baseline")
    File.cp_r!(root, target)
    write(target, "source.ex", "changed target must not be blessed")
    Overalls.HLDDMigration.run(target, root)
    assert Enum.any?(stale(target), &(&1.path == "source.ex"))

    [receipt] =
      Overalls.HLDDDocuments.read([
        Path.join(target, HLDDGate.receipt_path("source", "source.ex"))
      ])

    assert receipt["body"] =~ "Legacy reviewed fixture"
    assert receipt["data"]["digest"] == HLDDGate.digest(root, ["source.ex"])
    assert receipt["data"]["migration"]["system"]["source_digest"] == hd(groups)["source_digest"]
  end

  @spec stale(String.t()) :: [HLDDGate.review()]
  defp stale(root), do: Enum.reject(HLDDGate.status(root), &(&1.status == "current"))

  @spec git(String.t(), [String.t()]) :: String.t()
  defp git(root, arguments) do
    {output, status} = System.cmd("git", arguments, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
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

    Overalls.HLDDDocuments.write([
      %{
        "path" => Path.join(root, "marshall/priv/hldd/scenarios/recovery.yaml"),
        "data" => hd(data["scenarios"])
      }
    ])

    write(root, "marshall/priv/hldd/19-coverage.md", HLDDCoverage.render(data))
    write(root, "marshall/priv/hldd/01-system.md", "# System\n\nReviewed behavior.\n")
    Overalls.HLDDViewFixture.fixture(root)

    Overalls.HLDDDocuments.write([
      %{
        "path" => Path.join(root, "docs/hldd/groups/system.yaml"),
        "data" => %{
          "id" => "system",
          "prefixes" => [],
          "chapters" => ["01-system.md", "19-coverage.md", "21-domains.md", "22-topology.md"]
        }
      }
    ])

    data
  end
end
