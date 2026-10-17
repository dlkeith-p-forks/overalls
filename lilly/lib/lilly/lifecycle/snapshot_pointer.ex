defmodule Lilly.Lifecycle.SnapshotPointer do
  @moduledoc "Current snapshot binding; rebinding still requires retired predecessor evidence."
  use Lilly.Lifecycle.Resource,
    initial: [:initializing],
    edges: [initializing: [:initializing, :bound], bound: [:bound, :initializing]]
end
