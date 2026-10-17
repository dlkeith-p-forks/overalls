# @cc [owner:ghuntley,label:verification] lifecycle-diagrams-from-resources
# Diagrams MUST derive from the actual Ash resource graphs. They describe legal
# transitions, not physical evidence guards or proof that side effects succeeded.
resources =
  [Marshall.Compute, Lilly.Lifecycle]
  |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  |> Enum.filter(&(AshStateMachine in Spark.extensions(&1)))
  |> Enum.sort()

diagrams =
  Enum.map_join(resources, "\n", fn resource ->
    "## #{inspect(resource)}\n\n```mermaid\n" <>
      AshStateMachine.Charts.mermaid_state_diagram(resource) <> "\n```\n"
  end)

header = """
# Lifecycle state machines

Generated from Ash resources. Regenerate from Marshall with
`MIX_ENV=test mix run --no-start ../scripts/lifecycle_diagrams.exs`.

Desired state, physical observations, workflow progress and independent cleanup
evidence remain distinct. These graphs do not replace GUID, nonce, generation,
authorization or physical-evidence checks. See
[the lifecycle decision](decisions/0074-durable-lifecycle-state-machines.md).

"""

File.write!(
  Path.expand("../docs/architecture/lifecycle-state-machines.md", __DIR__),
  header <> diagrams
)
