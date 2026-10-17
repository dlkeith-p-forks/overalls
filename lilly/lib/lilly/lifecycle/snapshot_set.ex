defmodule Lilly.Lifecycle.SnapshotSet do
  @moduledoc "The single transfer snapshot's intent, GUID binding and irreversible retirement (ADR-0155)."
  use Lilly.Lifecycle.Resource,
    initial: [:creating, :retiring],
    edges: [
      creating: [:creating, :ready, :retiring],
      ready: [:ready, :retiring],
      retiring: [:retiring, :retired],
      retired: [:retired]
    ]
end
