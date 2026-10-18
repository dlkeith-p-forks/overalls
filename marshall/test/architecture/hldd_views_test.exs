Code.require_file("../../../scripts/hldd/coverage.ex", __DIR__)
Code.require_file("../../../scripts/hldd/views.ex", __DIR__)
Code.require_file("../../../scripts/hldd/gate.ex", __DIR__)
Code.require_file("hldd_helper.exs", __DIR__)

defmodule Overalls.HLDDViewsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.{HLDDGate, HLDDViews}
  import Overalls.HLDDViewFixture, only: [fixture: 1, snapshot: 0]

  setup do
    root =
      Path.join(System.tmp_dir!(), "hldd-views-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture(root)
    %{root: root}
  end

  @tag :hegel
  test "new domains and resource ownership changes invalidate the rendered view", %{
    root: root
  } do
    Hegel.check(
      fn ->
        suffix = draw("suffix", map(list(integer(65, 90), min: 1, max: 12), &List.to_string/1))
        change = draw("change", member_of([:domain, :resource, :delete]))
        fixture(root)
        assert HLDDViews.check(root, HLDDGate.files(root)) == []
        path = Path.join(root, "example/lib/domain.ex")

        case change do
          :domain ->
            File.write!(
              path,
              File.read!(path) <>
                "\ndefmodule Example.#{suffix} do\nuse Ash.Domain\nresources do\nresource Example.Item\nend\nend\n"
            )

          :resource ->
            File.write!(
              path,
              String.replace(
                File.read!(path),
                "resource Example.Item",
                "resource Example.#{suffix}Item"
              )
            )

          :delete ->
            File.write!(path, "defmodule Example.NoDomain do\nend\n")
        end

        refute HLDDViews.check(root, HLDDGate.files(root)) == []
      end,
      []
    )
  end

  @tag :hegel
  test "evaluated role, peer, port and instance changes cannot reuse a topology snapshot", %{
    root: root
  } do
    Hegel.check(
      fn ->
        port = draw("port", integer(1..65535))
        field = draw("field", member_of(~w(services fleetPeers adminSshPorts marshallInstances)))
        [host] = JSON.decode!(snapshot())
        value = if field == "adminSshPorts", do: [port, 2222], else: ["changed#{port}"]
        changed = JSON.encode!([Map.put(host, field, value)])

        assert HLDDViews.check(root, HLDDGate.files(root), changed) == [
                 "evaluated deployment topology is stale"
               ]
      end,
      []
    )
  end

  test "domain parsing ignores comments, deduplicates interfaces and retains resource ownership",
       %{root: root} do
    File.write!(Path.join(root, "example/lib/domain.ex"), """
    # use Ash.Domain
    defmodule Example.NotDomain do
      @doc "use Ash.Domain"
      def example, do: :ok
    end
    defmodule Example.Domain do
      use Ash.Domain
      resources do
        resource Example.Z
        resource Example.A do
          define :get_a
        end
        resource Example.A
      end
    end
    """)

    assert [%{name: "Example.Domain", resources: ["Example.A", "Example.Z"]}] =
             HLDDViews.domains(root, HLDDGate.files(root))
  end

  test "unsupported resource declarations fail without executing source", %{root: root} do
    path = Path.join(root, "example/lib/domain.ex")

    File.write!(path, """
    raise "must not execute"
    defmodule Example.Domain do
      use Ash.Domain
      resources do
        for item <- [Example.Item], do: resource(item)
      end
    end
    """)

    assert [error] = HLDDViews.check(root, HLDDGate.files(root))
    assert error =~ "unsupported dynamic Ash resource declaration"
    refute error =~ "must not execute"
  end

  test "new or removed fleet hosts fail even when the snapshot and chapter agree", %{root: root} do
    File.mkdir_p!(Path.join(root, "fleet/hosts/second"))
    File.write!(Path.join(root, "fleet/hosts/second/host.json"), "{}")
    assert HLDDViews.check(root, HLDDGate.files(root)) == ["topology host inventory is stale"]
    File.rm_rf!(Path.join(root, "fleet/hosts/second"))
    File.rm!(Path.join(root, "fleet/hosts/example/host.json"))
    assert HLDDViews.check(root, HLDDGate.files(root)) == ["topology host inventory is stale"]
  end

  test "required diagrams, per-entity text and verification prose cannot be removed", %{
    root: root
  } do
    for chapter <- ~w(21-domains.md 22-topology.md),
        pattern <- [
          ~r/```mermaid.*?```/s,
          ~r/^\| `[^`]+` \| .*$/m,
          ~r/## Verification and gaps.*\z/s,
          ~r/## Authority and interactions.*?(?=<!--)/s
        ] do
      fixture(root)
      path = Path.join(root, "marshall/priv/hldd/#{chapter}")
      File.write!(path, Regex.replace(pattern, File.read!(path), ""))
      refute HLDDViews.check(root, HLDDGate.files(root)) == []
    end
  end

  test "regeneration cannot hide a new domain's missing responsibility explanation", %{root: root} do
    path = Path.join(root, "example/lib/domain.ex")
    File.write!(path, String.replace(File.read!(path), "Example.Domain", "Example.NewDomain"))
    HLDDViews.write(root, HLDDGate.files(root), snapshot())

    assert Enum.any?(
             HLDDViews.check(root, HLDDGate.files(root)),
             &String.contains?(&1, "explanation for Example.NewDomain")
           )
  end

  test "topology projection rejects unexpected fields and diagram injection" do
    [host] = JSON.decode!(snapshot())

    for changed <- [
          Map.put(host, "environment", %{"TOKEN" => "fixture"}),
          Map.put(host, "services", ["a\"] --> injected"]),
          Map.put(host, "enrolled", "true")
        ] do
      assert_raise RuntimeError, fn -> HLDDViews.hosts(JSON.encode!([changed])) end
    end
  end
end
