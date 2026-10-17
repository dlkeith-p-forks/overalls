defmodule Lilly.Lifecycle.Import do
  @moduledoc "One full receive stream's progression and ownership retirement (ADR-0155)."
  use Lilly.Lifecycle.Resource,
    initial: [:receiving, :retiring],
    edges: [
      receiving: [:receiving, :received, :retiring],
      received: [:received, :retiring],
      retiring: [:retiring, :retired],
      retired: [:retired]
    ]
end
