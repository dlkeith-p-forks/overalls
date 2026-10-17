defmodule Lilly.Lifecycle.CloneCopy do
  @moduledoc "Same-pool block-cloned copy progression and ownership retirement (ADR-0145)."
  use Lilly.Lifecycle.Resource,
    initial: [:copying, :retiring],
    edges: [
      copying: [:copying, :copied, :retiring],
      copied: [:copied, :adopted, :retiring],
      adopted: [:adopted, :retiring],
      retiring: [:retiring, :retired],
      retired: [:retired]
    ]
end
