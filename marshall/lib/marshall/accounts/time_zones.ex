defmodule Marshall.Accounts.TimeZones do
  @moduledoc """
  Curated IANA time zones for the profile picker, display-only conversion of
  stored UTC instants and the difference between two people's local times.

  Storage stays UTC (ADR-0023/0047); every function here converts for display
  only, through the compiled `Tz` database, so no zone is fetched at runtime.
  Picker labels follow the `(GMT+09:30) Adelaide` form and use the offset in
  force at the given instant, so daylight saving is reflected.
  """

  use Gettext, backend: MarshallWeb.Gettext

  @utc "Etc/UTC"

  @typedoc "An IANA zone identifier such as `Australia/Adelaide`."
  @type iana :: String.t()

  @typedoc "How the viewer's zone was resolved."
  @type source :: :saved | :browser | :utc

  @typedoc "One picker entry; `offset` is the total UTC offset in seconds at the instant used."
  @type option :: %{label: String.t(), city: String.t(), zone: iana(), offset: integer()}

  @typedoc "Signed difference in minutes (positive means `other` is ahead) and its text."
  @type difference :: %{minutes: integer(), text: String.t()}

  @typedoc "Display formats accepted by `format/3`."
  @type format :: :datetime | :datetime_seconds | :date | :day_month | :time | :clock

  # Curated picker entries in the Rails `ActiveSupport::TimeZone::MAPPING`
  # style: one city per IANA zone so the picker has no duplicate ids.
  @curated [
    {"International Date Line West", "Etc/GMT+12"},
    {"Pago Pago", "Pacific/Pago_Pago"},
    {"Midway Island", "Pacific/Midway"},
    {"Honolulu", "Pacific/Honolulu"},
    {"Rarotonga", "Pacific/Rarotonga"},
    {"Marquesas", "Pacific/Marquesas"},
    {"Anchorage", "America/Anchorage"},
    {"Juneau", "America/Juneau"},
    {"Los Angeles", "America/Los_Angeles"},
    {"Vancouver", "America/Vancouver"},
    {"Tijuana", "America/Tijuana"},
    {"Denver", "America/Denver"},
    {"Edmonton", "America/Edmonton"},
    {"Phoenix", "America/Phoenix"},
    {"Chihuahua", "America/Chihuahua"},
    {"Mazatlan", "America/Mazatlan"},
    {"Chicago", "America/Chicago"},
    {"Winnipeg", "America/Winnipeg"},
    {"Regina", "America/Regina"},
    {"Mexico City", "America/Mexico_City"},
    {"Monterrey", "America/Monterrey"},
    {"Guatemala", "America/Guatemala"},
    {"Costa Rica", "America/Costa_Rica"},
    {"New York", "America/New_York"},
    {"Toronto", "America/Toronto"},
    {"Detroit", "America/Detroit"},
    {"Indianapolis", "America/Indiana/Indianapolis"},
    {"Havana", "America/Havana"},
    {"Bogota", "America/Bogota"},
    {"Lima", "America/Lima"},
    {"Panama", "America/Panama"},
    {"Halifax", "America/Halifax"},
    {"Caracas", "America/Caracas"},
    {"La Paz", "America/La_Paz"},
    {"Santiago", "America/Santiago"},
    {"Puerto Rico", "America/Puerto_Rico"},
    {"St. John's", "America/St_Johns"},
    {"Sao Paulo", "America/Sao_Paulo"},
    {"Buenos Aires", "America/Argentina/Buenos_Aires"},
    {"Montevideo", "America/Montevideo"},
    {"Guyana", "America/Guyana"},
    {"Nuuk", "America/Nuuk"},
    {"South Georgia", "Atlantic/South_Georgia"},
    {"Azores", "Atlantic/Azores"},
    {"Cape Verde", "Atlantic/Cape_Verde"},
    {"Reykjavik", "Atlantic/Reykjavik"},
    {"Dublin", "Europe/Dublin"},
    {"Lisbon", "Europe/Lisbon"},
    {"London", "Europe/London"},
    {"Casablanca", "Africa/Casablanca"},
    {"Monrovia", "Africa/Monrovia"},
    {"Abidjan", "Africa/Abidjan"},
    {"UTC", "Etc/UTC"},
    {"Belgrade", "Europe/Belgrade"},
    {"Bratislava", "Europe/Bratislava"},
    {"Budapest", "Europe/Budapest"},
    {"Ljubljana", "Europe/Ljubljana"},
    {"Prague", "Europe/Prague"},
    {"Sarajevo", "Europe/Sarajevo"},
    {"Skopje", "Europe/Skopje"},
    {"Warsaw", "Europe/Warsaw"},
    {"Zagreb", "Europe/Zagreb"},
    {"Brussels", "Europe/Brussels"},
    {"Copenhagen", "Europe/Copenhagen"},
    {"Madrid", "Europe/Madrid"},
    {"Paris", "Europe/Paris"},
    {"Amsterdam", "Europe/Amsterdam"},
    {"Berlin", "Europe/Berlin"},
    {"Zurich", "Europe/Zurich"},
    {"Rome", "Europe/Rome"},
    {"Stockholm", "Europe/Stockholm"},
    {"Oslo", "Europe/Oslo"},
    {"Vienna", "Europe/Vienna"},
    {"Lagos", "Africa/Lagos"},
    {"Algiers", "Africa/Algiers"},
    {"Bucharest", "Europe/Bucharest"},
    {"Cairo", "Africa/Cairo"},
    {"Helsinki", "Europe/Helsinki"},
    {"Kyiv", "Europe/Kyiv"},
    {"Riga", "Europe/Riga"},
    {"Sofia", "Europe/Sofia"},
    {"Tallinn", "Europe/Tallinn"},
    {"Vilnius", "Europe/Vilnius"},
    {"Athens", "Europe/Athens"},
    {"Istanbul", "Europe/Istanbul"},
    {"Minsk", "Europe/Minsk"},
    {"Jerusalem", "Asia/Jerusalem"},
    {"Beirut", "Asia/Beirut"},
    {"Amman", "Asia/Amman"},
    {"Harare", "Africa/Harare"},
    {"Johannesburg", "Africa/Johannesburg"},
    {"Kaliningrad", "Europe/Kaliningrad"},
    {"Moscow", "Europe/Moscow"},
    {"Volgograd", "Europe/Volgograd"},
    {"Samara", "Europe/Samara"},
    {"Kuwait", "Asia/Kuwait"},
    {"Riyadh", "Asia/Riyadh"},
    {"Nairobi", "Africa/Nairobi"},
    {"Baghdad", "Asia/Baghdad"},
    {"Tehran", "Asia/Tehran"},
    {"Dubai", "Asia/Dubai"},
    {"Muscat", "Asia/Muscat"},
    {"Baku", "Asia/Baku"},
    {"Tbilisi", "Asia/Tbilisi"},
    {"Yerevan", "Asia/Yerevan"},
    {"Mauritius", "Indian/Mauritius"},
    {"Kabul", "Asia/Kabul"},
    {"Yekaterinburg", "Asia/Yekaterinburg"},
    {"Karachi", "Asia/Karachi"},
    {"Tashkent", "Asia/Tashkent"},
    {"Kolkata", "Asia/Kolkata"},
    {"Colombo", "Asia/Colombo"},
    {"Kathmandu", "Asia/Kathmandu"},
    {"Dhaka", "Asia/Dhaka"},
    {"Almaty", "Asia/Almaty"},
    {"Omsk", "Asia/Omsk"},
    {"Novosibirsk", "Asia/Novosibirsk"},
    {"Yangon", "Asia/Yangon"},
    {"Bangkok", "Asia/Bangkok"},
    {"Ho Chi Minh City", "Asia/Ho_Chi_Minh"},
    {"Jakarta", "Asia/Jakarta"},
    {"Krasnoyarsk", "Asia/Krasnoyarsk"},
    {"Shanghai", "Asia/Shanghai"},
    {"Hong Kong", "Asia/Hong_Kong"},
    {"Kuala Lumpur", "Asia/Kuala_Lumpur"},
    {"Singapore", "Asia/Singapore"},
    {"Taipei", "Asia/Taipei"},
    {"Manila", "Asia/Manila"},
    {"Perth", "Australia/Perth"},
    {"Irkutsk", "Asia/Irkutsk"},
    {"Ulaanbaatar", "Asia/Ulaanbaatar"},
    {"Eucla", "Australia/Eucla"},
    {"Seoul", "Asia/Seoul"},
    {"Tokyo", "Asia/Tokyo"},
    {"Yakutsk", "Asia/Yakutsk"},
    {"Darwin", "Australia/Darwin"},
    {"Adelaide", "Australia/Adelaide"},
    {"Brisbane", "Australia/Brisbane"},
    {"Sydney", "Australia/Sydney"},
    {"Melbourne", "Australia/Melbourne"},
    {"Hobart", "Australia/Hobart"},
    {"Lord Howe Island", "Australia/Lord_Howe"},
    {"Vladivostok", "Asia/Vladivostok"},
    {"Guam", "Pacific/Guam"},
    {"Port Moresby", "Pacific/Port_Moresby"},
    {"Magadan", "Asia/Magadan"},
    {"Srednekolymsk", "Asia/Srednekolymsk"},
    {"Norfolk Island", "Pacific/Norfolk"},
    {"Honiara", "Pacific/Guadalcanal"},
    {"Noumea", "Pacific/Noumea"},
    {"Suva", "Pacific/Fiji"},
    {"Kamchatka", "Asia/Kamchatka"},
    {"Majuro", "Pacific/Majuro"},
    {"Auckland", "Pacific/Auckland"},
    {"Nuku'alofa", "Pacific/Tongatapu"},
    {"Fakaofo", "Pacific/Fakaofo"},
    {"Chatham Islands", "Pacific/Chatham"},
    {"Apia", "Pacific/Apia"},
    {"Kiritimati", "Pacific/Kiritimati"}
  ]

  @curated_ids MapSet.new(@curated, fn {_city, zone} -> zone end)

  @doc "The curated `{city, iana}` pairs in catalog order."
  @spec curated() :: [{String.t(), iana()}]
  def curated, do: @curated

  @doc "The zone used when nothing better is known."
  @spec utc() :: iana()
  def utc, do: @utc

  # @cc [owner:ghuntley,label:product] time-zone-options-current-offset
  # Every picker label MUST carry the zone's total UTC offset (utc_offset +
  # std_offset) at the supplied instant as `(GMT±HH:MM) City`, entries MUST
  # be ordered by that offset and then city, and no IANA id MAY appear twice.
  @doc "Picker entries sorted by the offset in force at `now`, then by city."
  @spec options(DateTime.t()) :: [option()]
  def options(%DateTime{} = now) do
    @curated
    |> Enum.map(fn {city, zone} -> option(city, zone, now) end)
    |> Enum.sort_by(&{&1.offset, &1.city})
  end

  @doc """
  A picker entry for one zone. Curated zones use their catalog city; any other
  valid zone (a browser zone, for example) is labelled from its identifier.
  """
  @spec option(iana(), DateTime.t()) :: option() | nil
  def option(zone, %DateTime{} = now) do
    case List.keyfind(@curated, zone, 1) do
      {city, ^zone} -> option(city, zone, now)
      nil -> if valid?(zone), do: option(city_from_id(zone), zone, now)
    end
  end

  @spec option(String.t(), iana(), DateTime.t()) :: option()
  defp option(city, zone, now) do
    offset = offset(zone, now)
    %{label: "(#{gmt_label(offset)}) #{city}", city: city, zone: zone, offset: offset}
  end

  # @cc [owner:ghuntley,label:security] time-zone-validation-closed
  # valid?/1 MUST accept only a binary that the compiled time zone database
  # resolves (curated or not); nil, non-binaries, blank, oversized or
  # unresolvable identifiers MUST be refused rather than stored or shifted.
  @doc "Whether `zone` is an identifier the compiled database can resolve."
  @spec valid?(term()) :: boolean()
  def valid?(zone) when is_binary(zone) and byte_size(zone) in 1..64 do
    MapSet.member?(@curated_ids, zone) or
      (String.printable?(zone) and match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), zone)))
  end

  def valid?(_), do: false

  @doc "Whether `zone` is one of the curated picker entries."
  @spec curated?(term()) :: boolean()
  def curated?(zone) when is_binary(zone), do: MapSet.member?(@curated_ids, zone)
  def curated?(_), do: false

  @doc "`now` expressed in `zone`; an unresolvable zone falls back to UTC."
  @spec local_now(iana() | nil, DateTime.t()) :: DateTime.t()
  def local_now(zone, %DateTime{} = now \\ DateTime.utc_now()), do: shift(now, zone)

  # @cc [owner:ghuntley,label:product] time-zone-shift-fails-to-utc
  # shift/2 MUST never raise for a stored or browser-supplied zone: an
  # unresolvable or nil zone MUST render the instant in UTC so every page
  # still shows a time.
  @doc "`instant` expressed in `zone`, or in UTC when the zone cannot be resolved."
  @spec shift(DateTime.t(), iana() | nil) :: DateTime.t()
  def shift(%DateTime{} = instant, zone) when is_binary(zone) do
    case DateTime.shift_zone(instant, zone) do
      {:ok, shifted} -> shifted
      {:error, _} -> DateTime.shift_zone!(instant, @utc)
    end
  end

  def shift(%DateTime{} = instant, _), do: DateTime.shift_zone!(instant, @utc)

  @doc "Total UTC offset of `zone` at `now`, in seconds."
  @spec offset(iana() | nil, DateTime.t()) :: integer()
  def offset(zone, %DateTime{} = now) do
    shifted = shift(now, zone)
    shifted.utc_offset + shifted.std_offset
  end

  @doc "The `GMT±HH:MM` text for an offset in seconds."
  @spec gmt_label(integer()) :: String.t()
  def gmt_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    minutes = div(abs(offset), 60)
    "GMT#{sign}#{pad(div(minutes, 60))}:#{pad(rem(minutes, 60))}"
  end

  # @cc [owner:ghuntley,label:product] time-zone-difference-antisymmetric
  # difference/3 MUST return the other zone's offset minus the viewer's in
  # whole minutes, so d(a, b) == -d(b, a) and d(a, a) == 0, and its text MUST
  # say "ahead of you" exactly when the sign is positive, "behind you" when
  # negative and "same time as you" when zero.
  @doc "How far `other` is ahead of (positive) or behind (negative) `viewer` at `now`."
  @spec difference(iana() | nil, iana() | nil, DateTime.t()) :: difference()
  def difference(viewer, other, %DateTime{} = now) do
    minutes = div(offset(other, now) - offset(viewer, now), 60)
    %{minutes: minutes, text: difference_text(minutes)}
  end

  @spec difference_text(integer()) :: String.t()
  defp difference_text(0), do: gettext("same time as you")

  defp difference_text(minutes) do
    hours = div(abs(minutes), 60)
    rest = rem(abs(minutes), 60)

    span =
      case {hours, rest} do
        {0, m} -> localized_unit(m, "minute")
        {h, 0} -> localized_unit(h, "hour")
        {h, m} -> localized_unit(h, "hour") <> " " <> localized_unit(m, "minute")
      end

    if minutes > 0,
      do: gettext("%{span} ahead of you", span: span),
      else: gettext("%{span} behind you", span: span)
  end

  @spec localized_unit(non_neg_integer(), String.t()) :: String.t()
  defp localized_unit(amount, unit) do
    amount |> Localize.Unit.new!(unit) |> Localize.Unit.to_string!(format: :narrow)
  end

  @doc """
  `instant` formatted in `zone`. Formats: `:datetime` (`2026-10-18 19:42 ACDT`),
  `:datetime_seconds`, `:date`, `:day_month` (`Oct 18` in English), `:time` (`19:42 ACDT`)
  and `:clock` (`7:42 PM ACDT`).
  """
  # @cc [owner:ghuntley,label:product] time-zone-localized-display
  # Human date/time fields MUST use the active Localize locale and bundled CLDR
  # data. The shifted instant and zone abbreviation MUST remain unchanged; the
  # UTC hover provenance remains an invariant ISO-style representation.
  @spec format(DateTime.t(), iana() | nil, format()) :: String.t()
  def format(%DateTime{} = instant, zone, format) do
    local = shift(instant, zone)

    case format do
      :datetime ->
        Localize.DateTime.to_string!(local, format: "yyyy-MM-dd HH:mm ") <> local.zone_abbr

      :datetime_seconds ->
        Localize.DateTime.to_string!(local, format: "yyyy-MM-dd HH:mm:ss ") <> local.zone_abbr

      :date ->
        Localize.Date.to_string!(local, format: "yyyy-MM-dd")

      :day_month ->
        Localize.Date.to_string!(local, format: :MMMd)

      :time ->
        Localize.Time.to_string!(local, format: "HH:mm ") <> local.zone_abbr

      :clock ->
        Localize.Time.to_string!(local, format: "h:mm a ") <> local.zone_abbr
    end
  end

  @doc "The UTC text shown on hover for a converted timestamp."
  @spec utc_text(DateTime.t()) :: String.t()
  def utc_text(%DateTime{} = instant),
    do: Calendar.strftime(DateTime.shift_zone!(instant, @utc), "%Y-%m-%d %H:%M:%S UTC")

  @doc "The calendar date of `instant` in `zone`."
  @spec local_date(DateTime.t(), iana() | nil) :: Date.t()
  def local_date(%DateTime{} = instant, zone), do: DateTime.to_date(shift(instant, zone))

  @spec city_from_id(iana()) :: String.t()
  defp city_from_id(zone) do
    zone |> String.split("/") |> List.last() |> String.replace("_", " ")
  end

  @spec pad(non_neg_integer()) :: String.t()
  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
