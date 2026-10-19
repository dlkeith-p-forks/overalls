defmodule MarshallWeb.GettextPlural do
  @moduledoc "Gettext plural callbacks that preserve Expo's opaque AST boundary."
  @behaviour Gettext.Plural

  @type context :: Gettext.Plural.pluralization_context()

  # @cc [owner:ghuntley,label:product;verification] gettext-plural-context-boundary
  # Generated backend code MUST embed only the locale and catalog header context,
  # never a literal Expo opaque AST. Plural callbacks MUST reconstruct that value
  # through Gettext's API and preserve explicit headers and locale fallback.
  # Each plural selection reparses its header; no runtime cache is introduced.
  @impl true
  @spec init(context()) :: context()
  def init(%{locale: "arz"} = context),
    do: Map.put_new(context, :plural_forms_header, plural_forms_header("arz"))

  def init(context), do: context

  @impl true
  @spec nplurals(context()) :: pos_integer()
  def nplurals(context) do
    context |> Gettext.Plural.init() |> Gettext.Plural.nplurals()
  end

  @impl true
  @spec plural(context(), integer()) :: non_neg_integer()
  def plural(context, count) do
    context |> Gettext.Plural.init() |> Gettext.Plural.plural(count)
  end

  @impl true
  @spec plural_forms_header(String.t()) :: String.t() | nil
  def plural_forms_header("arz"), do: Gettext.Plural.plural_forms_header("ar")
  def plural_forms_header(locale), do: Gettext.Plural.plural_forms_header(locale)
end
