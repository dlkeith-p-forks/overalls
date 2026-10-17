defmodule Lilly.Lifecycle.Resize do
  @moduledoc "GUID-bound disk growth intent, physical growth and verified publication."
  use Lilly.Lifecycle.Resource,
    initial: [:prepared],
    edges: [prepared: [:prepared, :grown], grown: [:grown, :confirmed], confirmed: [:confirmed]]
end
