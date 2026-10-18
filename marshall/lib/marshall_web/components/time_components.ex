defmodule MarshallWeb.TimeComponents do
  @moduledoc """
  Time presentation for the Monospace Web (ADR-0161): stored UTC instants
  rendered in the viewer's zone, a person's current local time beside their
  email, and the viewer's own clock. Conversion is display-only; the
  `datetime` attribute and hover title always carry the UTC instant.
  """
  use Phoenix.Component
  use Gettext, backend: MarshallWeb.Gettext
  alias Marshall.Accounts.TimeZones

  @doc """
  Renders a stored instant in `zone`. The element's `datetime` attribute and
  `title` keep the UTC instant so hovering shows it; a nil instant renders
  an em dash.
  """
  attr :at, :any, required: true, doc: "a UTC DateTime or nil"
  attr :zone, :string, default: nil, doc: "the viewer's IANA zone; nil renders UTC"

  attr :format, :atom,
    default: :datetime,
    values: [:datetime, :datetime_seconds, :date, :day_month, :time, :clock]

  attr :id, :string, default: nil
  attr :class, :any, default: nil

  # @cc [owner:ghuntley,label:product] timestamp-utc-provenance
  # Every converted timestamp MUST keep the UTC instant in its datetime
  # attribute and title and MUST name the zone abbreviation in its text for
  # formats that show a time of day, so a reader can tell which zone they
  # are looking at and recover the stored instant.
  @spec timestamp(map()) :: Phoenix.LiveView.Rendered.t()
  def timestamp(%{at: nil} = assigns) do
    ~H"""
    <span id={@id} class={["timestamp", @class]}>—</span>
    """
  end

  def timestamp(assigns) do
    ~H"""
    <time
      id={@id}
      class={["timestamp", @class]}
      datetime={DateTime.to_iso8601(@at)}
      title={TimeZones.utc_text(@at)}
      data-zone={@zone || TimeZones.utc()}
    >{TimeZones.format(@at, @zone, @format)}</time>
    """
  end

  @doc """
  Renders a person's email and, when they have saved a time zone, their
  current local time and the difference from the viewer. A person without a
  saved zone shows only the email.
  """
  attr :email, :any, required: true
  attr :time_zone, :any, default: nil, doc: "the person's saved IANA zone or nil"
  attr :viewer_zone, :string, default: nil
  attr :now, :any, required: true, doc: "the current UTC DateTime"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  # @cc [owner:ghuntley,label:security;product] person-local-time-saved-only
  # The local-time line MUST render only from the person's saved zone passed
  # by the caller; a nil zone MUST render the email alone. The component
  # MUST NOT infer a zone from the viewer's browser or any other person.
  @spec person(map()) :: Phoenix.LiveView.Rendered.t()
  def person(assigns) do
    ~H"""
    <span id={@id} class={["person", @class]}>
      <span class="person-email break">{@email}</span>
      <.local_time
        :if={is_binary(@time_zone)}
        zone={@time_zone}
        viewer_zone={@viewer_zone}
        now={@now}
        class="person-local"
      />
    </span>
    """
  end

  @doc """
  Renders another person's current local time and how far it is from the
  viewer's, such as `3:42 PM ACDT local time · 2h 30m ahead of you`.
  """
  attr :zone, :string, required: true, doc: "the person's saved IANA zone"
  attr :viewer_zone, :string, default: nil
  attr :now, :any, required: true, doc: "the current UTC DateTime"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  @spec local_time(map()) :: Phoenix.LiveView.Rendered.t()
  def local_time(assigns) do
    assigns =
      assign(
        assigns,
        :difference,
        TimeZones.difference(assigns.viewer_zone, assigns.zone, assigns.now)
      )

    ~H"""
    <span id={@id} class={["local-time muted", @class]} data-zone={@zone}>
      {gettext("%{value1} local time · %{value2}", value1: TimeZones.format(@now, @zone, :clock), value2: @difference.text)}
    </span>
    """
  end

  @doc "Renders the viewer's current local time in their zone."
  attr :zone, :string, default: nil
  attr :now, :any, required: true, doc: "the current UTC DateTime"
  attr :source, :atom, default: :utc, values: [:saved, :browser, :utc]
  attr :id, :string, default: "local-clock"
  attr :class, :any, default: nil

  @spec local_clock(map()) :: Phoenix.LiveView.Rendered.t()
  def local_clock(assigns) do
    ~H"""
    <time
      id={@id}
      class={["local-clock", @class]}
      datetime={DateTime.to_iso8601(@now)}
      title={(@zone || TimeZones.utc()) <> " · " <> TimeZones.utc_text(@now)}
      data-zone={@zone || TimeZones.utc()}
      data-zone-source={@source}
    >{TimeZones.format(@now, @zone, :clock)}</time>
    """
  end
end
