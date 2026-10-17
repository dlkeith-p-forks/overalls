defmodule Lilly.Lifecycle.BackupSnapshot do
  @moduledoc "One independent backup run's native snapshot intent and confirmed cleanup."
  use Lilly.Lifecycle.Resource,
    initial: [:creating],
    edges: [
      creating: [:creating, :ready, :cleaning],
      ready: [:ready, :cleaning],
      cleaning: [:cleaning, :cleaned],
      cleaned: [:cleaned]
    ]
end
