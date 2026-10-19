defmodule Marshall.LocalizationTest do
  use ExUnit.Case, async: true
  alias Marshall.Localization, as: Locale

  test "the complete supported set includes requested additions" do
    assert length(Locale.supported_locales()) == 28

    for locale <- ~w(ja hi fil et fi sv pt-BR pt-PT ar ur ko arz sw ha) do
      assert Locale.valid?(locale)
    end

    refute Locale.valid?("zz")
    refute Locale.valid?(%{})
    assert Locale.normalize("PT_br") == "pt-BR"
  end

  test "every supported locale has its own compiled Gettext catalog" do
    assert Enum.sort(Gettext.known_locales(MarshallWeb.Gettext)) ==
             Enum.sort(Locale.supported_locales())

    root = Application.app_dir(:marshall, "priv/gettext")

    domains =
      root |> Path.join("*.pot") |> Path.wildcard() |> Enum.map(&Path.basename(&1, ".pot"))

    refute "default" in domains

    assert ~w(shared auth account teams machines terminal agents integrations git inference editor ssh downloads browser documentation errors) --
             domains == []

    for locale <- Locale.supported_locales(), domain <- domains do
      path = Application.app_dir(:marshall, "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po")
      assert File.regular?(path), "missing #{locale}/#{domain}"

      assert path |> Expo.PO.parse_file!() |> Map.fetch!(:headers) |> IO.iodata_to_binary() =~
               "Language: #{locale}\n"
    end

    for locale <- Locale.supported_locales() do
      actual =
        root
        |> Path.join("#{locale}/LC_MESSAGES/*.po")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".po"))

      assert Enum.sort(actual) == Enum.sort(domains)
    end
  end

  test "precedence selects persisted user override before session and browser" do
    assert Locale.choose("ja", "fi", "sv") == "ja"
    assert Locale.choose(nil, "fi", "sv") == "fi"
    assert Locale.choose("zz", "invalid", "sv") == "sv"
    assert Locale.choose(nil, nil, nil) == "en"
  end

  test "browser negotiation respects quality, regions and unsupported scripts" do
    assert Locale.negotiate("fi;q=0.3, ja;q=0.9") == "ja"
    assert Locale.negotiate("pt-PT, en;q=0.8") == "pt-PT"
    assert Locale.negotiate("pt-BR, en;q=0.8") == "pt-BR"
    assert Locale.negotiate("zh-Hant, ja;q=0.8") == "ja"
    assert Locale.negotiate("zz-ZZ, ko;q=0.8") == "ko"
    assert Locale.negotiate("ja;q=0, fi;q=0.8") == "fi"
    assert Locale.negotiate(String.duplicate("a", 8193)) == nil
    assert Locale.negotiate(nil) == nil
  end

  test "direction comes from CLDR layout" do
    assert Locale.direction("ar") == :rtl
    assert Locale.direction("ur") == :rtl
    assert Locale.direction("ja") == :ltr
    assert Locale.direction("en") == :ltr
  end

  test "repeated direction lookup stays correct for the complete bounded policy" do
    for _ <- 1..10, locale <- Locale.supported_locales() do
      expected = if locale in ~w(ar ur arz), do: :rtl, else: :ltr
      assert Locale.direction(locale) == expected
    end

    for invalid <- [nil, %{}, "unsupported", "ar-EG", <<255>>, String.duplicate("a", 8193)] do
      assert Locale.direction(invalid) == :ltr
    end

    assert Locale.direction("ARZ") == :rtl
    assert Locale.direction("PT_br") == :ltr
  end

  test "language choices use native display names" do
    assert Enum.any?(Locale.options(), fn {name, locale} -> locale == "ja" and name != "ja" end)
  end

  test "request processes have independent translation locale state" do
    previous = Gettext.get_locale(MarshallWeb.Gettext)
    assert :ok = Locale.put_locale("ja")
    assert Gettext.get_locale(MarshallWeb.Gettext) == "ja"

    assert Task.async(fn ->
             Locale.put_locale("fi")
             Gettext.get_locale(MarshallWeb.Gettext)
           end)
           |> Task.await() == "fi"

    assert Gettext.get_locale(MarshallWeb.Gettext) == "ja"
    Gettext.put_locale(MarshallWeb.Gettext, previous)
  end

  # Ethnologue 2026 total-speaker ranking, independently transcribed from
  # Wikipedia revision 1380301586; Arabic varieties are separate ranked entries.
  test "the reviewed top twenty total-speaker languages remain covered" do
    for locale <- ~w(en zh-Hans hi es ar fr bn pt-BR id ur ru de ja pcm arz mr vi te sw ha) do
      assert locale in Locale.supported_locales()
    end
  end

  test "top twenty additions preserve catalog identity and use bundled formatting data" do
    assert Locale.normalize("ARZ") == "arz"
    assert Locale.formatting_locale("arz") == "ar-EG"
    assert Locale.direction("arz") == :rtl
    assert Locale.direction("sw") == :ltr
    assert Locale.direction("ha") == :ltr
    assert Locale.negotiate("arz-EG, en;q=0.8") == "arz"
    assert Locale.negotiate("sw-KE, en;q=0.8") == "sw"
    assert Locale.negotiate("ha-NG, en;q=0.8") == "ha"
    assert Locale.negotiate("ha-Arab, ja;q=0.8") == "ja"
    assert {"مصرى", "arz"} in Locale.options()

    for locale <- ~w(arz sw ha) do
      assert :ok = Locale.put_locale(locale)
      assert Gettext.get_locale(MarshallWeb.Gettext) == locale
      assert {:ok, _} = Localize.Locale.get(Localize.get_locale(), [:layout, :character_order])
      assert is_binary(Localize.Number.to_string!(1234))
    end
  end

  test "Egyptian Arabic uses all six Arabic plural categories" do
    context = MarshallWeb.GettextPlural.init(%{locale: "arz"})
    assert MarshallWeb.GettextPlural.nplurals(context) == 6

    assert Enum.map([0, 1, 2, 3, 11, 100], &MarshallWeb.GettextPlural.plural(context, &1)) ==
             [0, 1, 2, 3, 4, 5]
  end
end
