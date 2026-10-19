defmodule Marshall.Android.DisplayRegistryTest do
  use ExUnit.Case, async: false
  alias Marshall.Android.{DisplayRegistry, DisplayRelay}

  test "shares one relay per machine generation" do
    assert is_pid(Process.whereis(DisplayRegistry))
    machine_id = "display-registry-test-#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, first} = DisplayRegistry.relay({machine_id, 7})
    on_exit(fn -> if Process.alive?(first), do: GenServer.stop(first, :normal, 5_000) end)
    assert {:ok, ^first} = DisplayRegistry.relay({machine_id, 7})
    assert {:ok, second} = DisplayRegistry.relay({machine_id, 8})
    on_exit(fn -> if Process.alive?(second), do: GenServer.stop(second, :normal, 5_000) end)
    assert first != second
    assert DisplayRelay.attach(first, self(), :viewer) == :ok
  end
end
