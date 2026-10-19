defmodule Porsche.GettextInterpolationTest do
  use ExUnit.Case, async: true

  alias Porsche.GettextInterpolation

  test "RTL interpolation isolates a mixed-script value through the configured backend" do
    Gettext.with_locale(Porsche.Gettext, "ar", fn ->
      rendered = Gettext.gettext(Porsche.Gettext, "Request %{id}: submitting", id: "alice-123")
      assert rendered =~ "\u2068alice-123\u2069"
      refute rendered =~ "\u2068\u2068"
    end)
  end

  test "LTR values and missing-binding behavior retain Gettext semantics" do
    Gettext.with_locale(Porsche.Gettext, "en", fn ->
      assert GettextInterpolation.runtime_interpolate("Hello %{name}", %{name: "Alice"}) ==
               {:ok, "Hello Alice"}

      assert GettextInterpolation.runtime_interpolate("Hello %{name}", %{}) ==
               {:missing_bindings, "Hello %{name}", [:name]}
    end)
  end

  test "RTL missing bindings and numeric values preserve placeholders" do
    Gettext.with_locale(Porsche.Gettext, "ur", fn ->
      assert {:missing_bindings, rendered, [:name]} =
               GettextInterpolation.runtime_interpolate("%{count}: %{name}", %{count: 3})

      assert rendered == "\u20683\u2069: %{name}"
    end)
  end

  test "Egyptian Arabic isolates mixed-script bindings without changing catalog locale" do
    Gettext.with_locale(Porsche.Gettext, "arz", fn ->
      assert {:ok, rendered} =
               GettextInterpolation.runtime_interpolate("%{name}", %{name: "alice-علي-123"})
      assert rendered == "\u2068alice-علي-123\u2069"
      assert Gettext.get_locale(Porsche.Gettext) == "arz"
    end)
  end
end
