defmodule Marshall.Editor.RuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    names = ["MARSHALL_INGRESS_ZONE", "MARSHALL_INGRESS_EDITOR_RELEASES"]
    previous = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;protocol] editor-runtime-disabled-zone
  # An empty validated registry MUST preserve single-label generic ingress.
  # Nonempty registries MUST reject it and accept a canonical multi-label zone.
  test "runtime applies the editor zone boundary only to nonempty valid registries" do
    System.put_env("MARSHALL_INGRESS_ZONE", "local")
    empty = %{"version" => 1, "targets" => %{}}
    System.put_env("MARSHALL_INGRESS_EDITOR_RELEASES", JSON.encode!(empty))
    assert runtime()[:marshall][:ingress_editor_releases] == empty

    valid = Marshall.EditorFixture.releases()
    System.put_env("MARSHALL_INGRESS_EDITOR_RELEASES", JSON.encode!(valid))
    assert_raise RuntimeError, "Invalid editor MARSHALL_INGRESS_ZONE", &runtime/0
    System.put_env("MARSHALL_INGRESS_ZONE", "example.test")
    assert runtime()[:marshall][:ingress_editor_releases] == valid

    for value <- ["{}", "not-json", String.duplicate(" ", 4097)] do
      System.put_env("MARSHALL_INGRESS_EDITOR_RELEASES", value)
      assert_raise RuntimeError, "Invalid MARSHALL_INGRESS_EDITOR_RELEASES", &runtime/0
    end
  end

  @spec runtime() :: keyword()
  defp runtime, do: Config.Reader.read!("config/runtime.exs", env: :test, target: :host)

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
