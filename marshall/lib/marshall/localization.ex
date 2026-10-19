defmodule Marshall.Localization do
  @moduledoc "Locale policy for browser and authenticated Marshall requests."

  @type locale :: String.t()
  @type direction :: :ltr | :rtl

  @locale_strings ~w(en zh-Hans hi es ar fr bn pt-BR pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv arz sw ha)

  @spec supported_locales() :: [locale()]
  def supported_locales, do: @locale_strings

  @spec default() :: locale()
  def default, do: "en"

  @spec valid?(term()) :: boolean()
  def valid?(locale), do: normalize(locale) in @locale_strings

  @spec normalize(term()) :: locale() | nil
  def normalize(locale) when is_atom(locale), do: locale |> Atom.to_string() |> normalize()

  def normalize(locale) when is_binary(locale) do
    locale = if String.valid?(locale), do: String.trim(locale), else: ""

    canonical =
      locale
      |> String.replace("_", "-")
      |> String.split("-", trim: true)
      |> Enum.with_index()
      |> Enum.map(fn {part, index} -> if index == 0, do: String.downcase(part), else: part end)
      |> Enum.join("-")

    Enum.find(@locale_strings, fn supported ->
      String.downcase(supported) == String.downcase(canonical)
    end)
  end

  def normalize(_), do: nil

  @spec formatting_locale(term()) :: String.t()
  def formatting_locale(locale) do
    locale |> normalize() |> OverallsProtocol.SSHManagement.formatting_locale()
  end

  @spec direction(term()) :: direction()
  def direction(locale) do
    with {:ok, tag} <- Localize.LanguageTag.new(formatting_locale(locale)),
         {:ok, direction} when direction in [:rtl, :ltr] <-
           Localize.Locale.get(tag, [:layout, :character_order]) do
      direction
    else
      _ -> :ltr
    end
  end

  @spec options() :: [{String.t(), locale()}]
  def options do
    Enum.map(@locale_strings, fn locale ->
      name =
        case native_name(locale) do
          {:ok, name} -> name
          _ -> locale
        end

      {name, locale}
    end)
  end

  # @cc [owner:ghuntley,label:product] egyptian-arabic-autonym
  # The language selector MUST distinguish Egyptian Arabic from Standard Arabic.
  # Localize lacks an `arz` display name; its reviewed autonym MUST remain visible.
  @spec native_name(locale()) :: {:ok, String.t()} | {:error, term()}
  defp native_name("arz"), do: {:ok, "مصرى"}

  defp native_name(locale),
    do: Localize.Locale.display_name(locale, locale: formatting_locale(locale))

  @spec choose(term(), term(), term()) :: locale()
  def choose(user_override, session_locale, accept_language) do
    normalize(user_override) || normalize(session_locale) || negotiate(accept_language) ||
      default()
  end

  @spec put_locale(locale()) :: :ok
  def put_locale(locale) do
    locale = normalize(locale) || default()
    Gettext.put_locale(MarshallWeb.Gettext, locale)
    Localize.put_locale(formatting_locale(locale))
    :ok
  end

  @spec assign_socket(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_socket(socket, session) do
    user = socket.assigns[:current_user]
    override = if is_map(user), do: Map.get(user, :locale)
    locale = choose(override, session["locale"], nil)
    put_locale(locale)

    socket
    |> Phoenix.Component.assign(:locale, locale)
    |> Phoenix.Component.assign(:direction, direction(locale))
  end

  # @cc [owner:ghuntley,label:security] locale-header-boundary
  # Untrusted language headers never create atoms or escape the supported locale
  # allowlist. CLDR supplies language matching; explicit script differences must
  # not silently select a different writing system.
  @spec negotiate(term()) :: locale() | nil
  def negotiate(header) when is_binary(header) and byte_size(header) <= 8192 do
    header = if String.valid?(header), do: header, else: ""

    header
    |> Localize.AcceptLanguage.tokenize()
    |> Enum.find_value(fn {_quality, requested} ->
      with {:ok, tag} <- Localize.AcceptLanguage.best_match(requested),
           supported when is_binary(supported) <-
             canonical_supported(if tag.language == :arz, do: :arz, else: tag.cldr_locale_id),
           true <- compatible_script?(requested, supported) do
        supported
      else
        _ -> nil
      end
    end)
  end

  def negotiate(_), do: nil

  @spec canonical_supported(atom()) :: locale() | nil
  defp canonical_supported(:pt), do: "pt-BR"
  defp canonical_supported(:zh), do: "zh-Hans"
  defp canonical_supported(locale), do: normalize(locale)

  @spec compatible_script?(String.t(), locale()) :: boolean()
  defp compatible_script?(requested, supported) do
    with {:ok, requested_tag} <- Localize.LanguageTag.new(requested),
         {:ok, supported_tag} <- Localize.LanguageTag.new(supported) do
      requested_tag.script == supported_tag.script
    else
      _ -> false
    end
  end
end
