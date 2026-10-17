defmodule Overalls.HLDDViewFixture do
  alias Overalls.{HLDDGate, HLDDViews}

  @spec fixture(String.t()) :: :ok
  def fixture(root) do
    for directory <- ~w(example/lib fleet/hosts/example marshall/priv/hldd) do
      File.mkdir_p!(Path.join(root, directory))
    end

    File.write!(Path.join(root, "example/lib/domain.ex"), """
    defmodule Example.Domain do
      use Ash.Domain
      resources do
        resource Example.Item
      end
    end
    """)

    File.write!(Path.join(root, "fleet/hosts/example/host.json"), "{}")

    for {chapter, name} <- [{"21-domains.md", "Example.Domain"}, {"22-topology.md", "example"}] do
      File.write!(Path.join(root, "marshall/priv/hldd/#{chapter}"), """
      # View

      | `#{name}` | Owns fixture state within the documented application boundary; no separate deployment authority is implied. |

      ## Authority and interactions

      Fixture authority is local and scoped to this isolated example. The diagram does not establish deployment health or policy correctness. [Source](repo:example/lib/domain.ex).

      ```mermaid
      flowchart LR
        Caller --> Authority
      ```

      <!-- hldd:view:start -->
      <!-- hldd:view:end -->

      ## Verification and gaps

      Fixture evidence is structural only. Machine tests and property-based authority histories remain necessary for actual security boundaries. [Source](repo:example/lib/domain.ex).
      """)
    end

    HLDDViews.write(root, HLDDGate.files(root), snapshot())
  end

  @spec snapshot() :: String.t()
  def snapshot do
    JSON.encode!([
      %{
        "name" => "example",
        "enrolled" => true,
        "services" => ["lilly"],
        "marshallInstances" => [],
        "fleetAddress" => "10.90.0.1",
        "fleetPeers" => [],
        "adminSshPorts" => [2222]
      }
    ])
  end
end
