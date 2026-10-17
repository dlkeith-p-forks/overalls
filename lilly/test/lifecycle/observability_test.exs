defmodule Lilly.Lifecycle.ObservabilityTest do
  use ExUnit.Case, async: false
  alias Lilly.Lifecycle.Observability

  test "dynamic transitions reject incomplete and unreviewed metadata before socket access" do
    metadata = %{
      event_id: Lilly.UUID.generate(),
      resource_id: Lilly.UUID.generate(),
      resource_type: :dataset,
      action: :initialize_creating,
      next_state: :creating,
      revision: 1,
      occurred_at: 1_800_000_000_000_000
    }

    for invalid <- [
          Map.delete(metadata, :resource_id),
          Map.put(metadata, :event_id, "private-invalid-id"),
          Map.put(metadata, :payload, "private-payload"),
          Map.put(metadata, :next_state, "creating"),
          Map.put(metadata, :revision, 0),
          Map.put(metadata, :occurred_at, 0)
        ] do
      assert {:error, :invalid} = Observability.enqueue_transition(invalid)
    end
  end
end
