defmodule Lilly.Lifecycle.Dataset do
  @moduledoc "Owned ZFS dataset creation, adoption and irreversible retirement."
  use Lilly.Lifecycle.Resource,
    initial: [:creating, :importing],
    edges: [
      creating: [:creating, :bound, :deleting],
      bound: [:bound, :ready, :deleting],
      ready: [:ready, :deleting, :"import-deleting"],
      importing: [:importing, :"import-pruned", :"import-deleting"],
      "import-pruned": [:"import-pruned", :"import-publishing", :"import-deleting"],
      "import-publishing": [:"import-publishing", :ready, :"import-deleting"],
      "import-deleting": [:"import-deleting", :deleted],
      deleting: [:deleting, :deleted],
      deleted: [:deleted]
    ]
end
