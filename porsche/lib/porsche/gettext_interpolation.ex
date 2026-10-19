defmodule Porsche.GettextInterpolation do
  @moduledoc "Gettext placeholder compatibility with Localize bidirectional isolation."
  @behaviour Gettext.Interpolation

  # @cc [owner:ghuntley,label:product] porsche-gettext-bidi-isolation
  # RTL human messages MUST isolate substituted values using Localize's MF2
  # formatter. Source identifiers and Gettext placeholder/plural syntax MUST stay
  # stable; LTR output and missing-binding behavior MUST retain Gettext semantics.
  @impl Gettext.Interpolation
  @spec runtime_interpolate(String.t(), Gettext.Interpolation.bindings()) ::
          {:ok, String.t()} | {:missing_bindings, String.t(), [atom()]}
  def runtime_interpolate(message, bindings) do
    locale =
      Porsche.Gettext
      |> Gettext.get_locale()
      |> OverallsProtocol.SSHManagement.formatting_locale()

    bindings =
      if map_size(bindings) > 0 and rtl?(locale) do
        Map.new(bindings, fn {key, value} ->
          {key,
           Localize.Message.format!("{$value}", %{"value" => to_string(value)},
             locale: locale,
             bidi: :isolate
           )}
        end)
      else
        bindings
      end

    Gettext.Interpolation.Default.runtime_interpolate(message, bindings)
  end

  @impl Gettext.Interpolation
  defmacro compile_interpolate(_translation_type, message, bindings) do
    quote do
      Porsche.GettextInterpolation.runtime_interpolate(unquote(message), unquote(bindings))
    end
  end

  @impl Gettext.Interpolation
  @spec message_format() :: String.t()
  def message_format, do: Gettext.Interpolation.Default.message_format()

  @spec rtl?(String.t()) :: boolean()
  defp rtl?(locale) do
    with {:ok, tag} <- Localize.LanguageTag.new(locale) do
      Localize.Locale.get(tag, [:layout, :character_order]) == {:ok, :rtl}
    else
      _ -> false
    end
  end
end
