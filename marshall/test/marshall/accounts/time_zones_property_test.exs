defmodule Marshall.Accounts.TimeZonesPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.TimeZones

  # Instants from 2000 through 2040 cover many northern and southern daylight
  # saving transitions; the fixed list below pins known transition edges.
  @range DateTime.to_unix(~U[2000-01-01 00:00:00Z])..DateTime.to_unix(~U[2040-12-31 23:59:59Z])
  @edges [
    ~U[2026-04-04 16:29:59Z],
    ~U[2026-04-04 16:30:00Z],
    ~U[2026-10-03 16:29:59Z],
    ~U[2026-10-03 16:30:00Z],
    ~U[2026-03-29 00:59:59Z],
    ~U[2026-03-29 01:00:00Z],
    ~U[2026-11-01 05:59:59Z],
    ~U[2026-11-01 06:00:00Z]
  ]

  defp instant do
    one_of([
      member_of(@edges),
      map(integer(@range), &DateTime.from_unix!/1)
    ])
  end

  defp zone, do: member_of(Enum.map(TimeZones.curated(), &elem(&1, 1)))

  property "every label carries the zone's offset in force at that instant" do
    now = draw("now", instant())
    pair = draw("pair", member_of(TimeZones.curated()))
    {city, zone} = pair
    shifted = DateTime.shift_zone!(now, zone)
    total = shifted.utc_offset + shifted.std_offset
    option = Enum.find(TimeZones.options(now), &(&1.zone == zone))

    assert option.offset == total
    assert option.city == city
    assert option.label == "(#{TimeZones.gmt_label(total)}) #{city}"
    assert Regex.match?(~r/\A\(GMT[+-]\d{2}:\d{2}\) .+\z/, option.label)
    minutes = div(abs(total), 60)
    assert option.label =~ "#{pad(div(minutes, 60))}:#{pad(rem(minutes, 60))}"
  end

  test "half-hour and 45-minute zones label their exact offsets" do
    winter = ~U[2026-07-01 00:00:00Z]
    summer = ~U[2026-12-01 00:00:00Z]
    labels = fn now -> Map.new(TimeZones.options(now), &{&1.zone, &1.label}) end

    assert labels.(winter)["Australia/Adelaide"] == "(GMT+09:30) Adelaide"
    assert labels.(summer)["Australia/Adelaide"] == "(GMT+10:30) Adelaide"
    assert labels.(winter)["Asia/Kathmandu"] == "(GMT+05:45) Kathmandu"
    assert labels.(winter)["Pacific/Chatham"] == "(GMT+12:45) Chatham Islands"
    assert labels.(summer)["Pacific/Chatham"] == "(GMT+13:45) Chatham Islands"
    assert labels.(winter)["Etc/UTC"] == "(GMT+00:00) UTC"
    assert labels.(winter)["America/St_Johns"] == "(GMT-02:30) St. John's"
  end

  property "options are sorted by offset then city and contain every curated zone once" do
    now = draw("now", instant())
    options = TimeZones.options(now)
    assert options == Enum.sort_by(options, &{&1.offset, &1.city})
    assert length(options) == length(TimeZones.curated())
    zones = Enum.map(options, & &1.zone)
    assert zones == Enum.uniq(zones)
    assert MapSet.new(zones) == MapSet.new(TimeZones.curated(), &elem(&1, 1))
  end

  property "difference is antisymmetric, zero on itself and its text follows the sign" do
    now = draw("now", instant())
    a = draw("a", zone())
    b = draw("b", zone())
    ab = TimeZones.difference(a, b, now)
    ba = TimeZones.difference(b, a, now)
    assert ab.minutes == -ba.minutes
    assert TimeZones.difference(a, a, now) == %{minutes: 0, text: "same time as you"}
    assert ab.minutes == div(TimeZones.offset(b, now) - TimeZones.offset(a, now), 60)

    cond do
      ab.minutes > 0 -> assert String.ends_with?(ab.text, " ahead of you")
      ab.minutes < 0 -> assert String.ends_with?(ab.text, " behind you")
      true -> assert ab.text == "same time as you"
    end

    hours = div(abs(ab.minutes), 60)
    rest = rem(abs(ab.minutes), 60)
    if hours > 0, do: assert(ab.text =~ "#{hours}h")
    if rest > 0, do: assert(ab.text =~ "#{rest}m")
    if ab.minutes != 0 and rest == 0, do: refute(ab.text =~ ~r/\dm /)
  end

  property "every curated zone is valid and shifting preserves the instant" do
    now = draw("now", instant())
    zone = draw("zone", zone())
    assert TimeZones.valid?(zone)
    shifted = TimeZones.shift(now, zone)
    assert DateTime.compare(shifted, now) == :eq
    assert shifted.time_zone == zone
    assert TimeZones.format(now, zone, :datetime) =~ ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2} \S+\z/
    assert TimeZones.format(now, zone, :clock) =~ ~r/\A\d{1,2}:\d{2} [AP]M \S+\z/
    assert TimeZones.utc_text(now) =~ ~r/ UTC\z/
  end

  property "arbitrary text is refused unless the database resolves it" do
    text = draw("text", one_of([string(:printable, max_length: 70), binary(max_length: 70)]))

    resolvable =
      is_binary(text) and byte_size(text) in 1..64 and String.printable?(text) and
        match?({:ok, _}, DateTime.shift_zone(~U[2026-01-01 00:00:00Z], text))

    assert TimeZones.valid?(text) == (resolvable or TimeZones.curated?(text))
    refute TimeZones.valid?(nil)
    refute TimeZones.valid?("")
    refute TimeZones.valid?(String.duplicate("a", 65))
    # An unresolvable zone never raises; it renders in UTC.
    assert TimeZones.shift(~U[2026-01-01 00:00:00Z], text).time_zone in [text, "Etc/UTC"]
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
