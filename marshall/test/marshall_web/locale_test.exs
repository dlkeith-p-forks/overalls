defmodule Marshall.LocalizationTest do
  use ExUnit.Case, async: true
  alias Marshall.Localization, as: Locale

  test "the complete supported set includes requested additions" do
    assert length(Locale.supported_locales()) == 25

    for locale <- ~w(ja hi fil et fi sv pt-BR pt-PT ar ur ko) do
      assert Locale.valid?(locale)
    end

    refute Locale.valid?("zz")
    refute Locale.valid?(%{})
    assert Locale.normalize("PT_br") == "pt-BR"
  end

  test "every supported locale has its own compiled Gettext catalog" do
    assert Enum.sort(Gettext.known_locales(MarshallWeb.Gettext)) ==
             Enum.sort(Locale.supported_locales())

    for locale <- Locale.supported_locales(),
        domain <- ~w(default browser documentation errors) do
      path = Application.app_dir(:marshall, "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po")
      assert File.regular?(path), "missing #{locale}/#{domain}"

      assert path |> Expo.PO.parse_file!() |> Map.fetch!(:headers) |> IO.iodata_to_binary() =~
               "Language: #{locale}\n"
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
end
