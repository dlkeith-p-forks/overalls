defmodule Marshall.Accounts.LocalizedTimeZonesTest do
  use ExUnit.Case, async: true

  alias Marshall.Accounts.TimeZones
  alias Marshall.Localization

  test "every supported locale formats shifted instants without changing UTC provenance" do
    instant = ~U[2026-10-18 10:12:34Z]
    expected_utc = "2026-10-18 10:12:34 UTC"

    for locale <- Localization.supported_locales() do
      Localization.put_locale(locale)

      for format <- [:datetime, :datetime_seconds, :date, :day_month, :time, :clock] do
        rendered = TimeZones.format(instant, "Asia/Tokyo", format)
        assert is_binary(rendered) and byte_size(rendered) > 0, "#{locale}/#{format}"
      end

      difference = TimeZones.difference("Etc/UTC", "Asia/Kolkata", instant)
      assert difference.minutes == 330
      assert is_binary(difference.text) and byte_size(difference.text) > 0
      assert TimeZones.utc_text(instant) == expected_utc
      assert DateTime.compare(TimeZones.shift(instant, "Asia/Tokyo"), instant) == :eq
      assert TimeZones.format(instant, "Asia/Tokyo", :datetime) =~ "JST"
    end
  end

  test "month names and ordering follow the active locale" do
    instant = ~U[2026-10-18 10:12:34Z]
    Localization.put_locale("en")
    english = TimeZones.format(instant, "Etc/UTC", :day_month)
    Localization.put_locale("ja")
    japanese = TimeZones.format(instant, "Etc/UTC", :day_month)
    assert english =~ "Oct"
    assert japanese =~ "月"
    refute japanese == english
    assert TimeZones.utc_text(instant) == "2026-10-18 10:12:34 UTC"
  end
end
