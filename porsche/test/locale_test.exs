defmodule Porsche.LocaleTest do
  use ExUnit.Case, async: true

  test "only validated authenticated preferences become display locales" do
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "ja"}}) == "ja"
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "ar"}}) == "ar"
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "invalid"}}) == "en"
    assert Porsche.Locale.from_session(%{"status" => "pending"}) == "en"
    assert Porsche.Locale.from_session(nil) == "en"
  end
end
