defmodule Marshall.Android.DisplayRegistryTest do
  use ExUnit.Case, async: false
  alias Marshall.Android.{DisplayRegistry, DisplayRelay}

  test "shares one relay per machine generation" do
    start_supervised!({DisplayRegistry, []})
    assert {:ok, first} = DisplayRegistry.relay({"machine-a", 7})
    assert {:ok, ^first} = DisplayRegistry.relay({"machine-a", 7})
    assert {:ok, second} = DisplayRegistry.relay({"machine-a", 8})
    assert first != second
    assert DisplayRelay.attach(first, self(), :viewer) == :ok
  end
end
