defmodule Lilly.Lifecycle.GuestTrust do
  @moduledoc "Boot-bound public CA delivery and confirmed guest installation, or its recorded skip for agentless guests."
  use Lilly.Lifecycle.Resource,
    initial: [:pending, :skipped],
    edges: [
      pending: [:pending, :delivering, :skipped],
      skipped: [:skipped],
      delivering: [:delivering, :installed, :failed, :pending],
      installed: [:installed, :pending],
      failed: [:failed, :delivering, :pending]
    ]
end
