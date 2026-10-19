defmodule Porsche.LocaleTest do
  use ExUnit.Case, async: true

  test "only validated authenticated preferences become display locales" do
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "ja"}}) == "ja"
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "ar"}}) == "ar"
    assert Porsche.Locale.from_session(%{"user" => %{"locale" => "invalid"}}) == "en"
    assert Porsche.Locale.from_session(%{"status" => "pending"}) == "en"
    assert Porsche.Locale.from_session(nil) == "en"
  end

  test "new top twenty preferences stay separate from CLDR formatting identity" do
    for locale <- ~w(arz sw ha) do
      session = %{"user" => %{"locale" => locale}}
      assert Porsche.Locale.from_session(session) == locale
      assert :ok = Porsche.Locale.put_locale(session)
      assert Gettext.get_locale(Porsche.Gettext) == locale
      assert {:ok, _} = Localize.Locale.get(Localize.get_locale(), [:layout, :character_order])
    end

    context = Porsche.GettextPlural.init(%{locale: "arz"})
    assert Porsche.GettextPlural.nplurals(context) == 6
    assert Enum.map([0, 1, 2, 3, 11, 100], &Porsche.GettextPlural.plural(context, &1)) ==
             [0, 1, 2, 3, 4, 5]
  end
end
