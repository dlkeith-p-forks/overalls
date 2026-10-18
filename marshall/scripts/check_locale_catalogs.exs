defmodule Marshall.LocaleCatalogCheck do
  @moduledoc "Checks catalog identity and reports translation gaps without counting source copies as translations."
  @type counts :: %{
          total: non_neg_integer(),
          empty: non_neg_integer(),
          source_equal: non_neg_integer(),
          invalid: non_neg_integer(),
          fuzzy: non_neg_integer()
        }

  # @cc [owner:ghuntley,label:verification] catalog-coverage-honesty
  # Every policy locale MUST have every extracted domain. Empty and source-equal
  # entries and fuzzy flags MUST be reported separately; none establishes translated
  # coverage. Duplicate or obsolete identities MUST never silently mask messages.
  @spec run([String.t()]) :: :ok
  def run(args) do
    root = Path.expand("../priv/gettext", __DIR__)
    locales = Marshall.Localization.supported_locales()
    domains = Path.wildcard(Path.join(root, "*.pot"))

    gaps =
      for locale <- locales, template <- domains do
        domain = Path.basename(template, ".pot")
        path = Path.join([root, locale, "LC_MESSAGES", domain <> ".po"])
        source = Expo.PO.parse_file!(template)
        catalog = Expo.PO.parse_file!(path)
        headers = IO.iodata_to_binary(catalog.headers)

        unless "Language: #{locale}\n" in catalog.headers,
          do: raise("Catalog language header differs from policy: #{path}")

        [_, plural_expression] = Regex.run(~r/Plural-Forms: ([^\n]+)/, headers)
        plural = Expo.PluralForms.parse!(plural_expression)

        for %Expo.Message.Plural{} = message <- catalog.messages do
          unless Enum.sort(Map.keys(message.msgstr)) == Enum.to_list(0..(plural.nplurals - 1)),
            do: raise("Missing or excess plural forms in #{path}: #{inspect(message.msgid)}")
        end

        if Enum.any?(catalog.messages, & &1.obsolete),
          do: raise("Obsolete catalog messages must be removed: #{path}")

        expected = Map.new(source.messages, &{Expo.Message.key(&1), &1})
        actual = Map.new(catalog.messages, &{Expo.Message.key(&1), &1})

        unless map_size(actual) == length(catalog.messages),
          do: raise("Duplicate catalog message identities: #{path}")

        unless MapSet.new(Map.keys(expected)) == MapSet.new(Map.keys(actual)),
          do: raise("Catalog message identities differ: #{path}")

        counts =
          Enum.reduce(
            catalog.messages,
            %{total: 0, empty: 0, source_equal: 0, invalid: 0, fuzzy: 0},
            fn message, counts -> count(message, counts, domain) end
          )

        IO.puts(
          "#{locale}/#{domain}: total=#{counts.total} empty=#{counts.empty} source_equal=#{counts.source_equal} fuzzy=#{counts.fuzzy} invalid=#{counts.invalid}"
        )

        {if(locale == "en", do: 0, else: counts.empty + counts.source_equal + counts.fuzzy), counts.invalid}
      end

    if Enum.any?(gaps, fn {_missing, invalid} -> invalid > 0 end),
      do: raise("Catalog placeholder or documentation structure errors remain")

    if "--strict" in args and Enum.any?(gaps, fn {missing, _invalid} -> missing > 0 end),
      do: raise("Untranslated catalog entries remain; see empty and source_equal counts above")

    :ok
  end

  @spec count(Expo.Message.t(), counts(), String.t()) :: counts()
  defp count(message, counts, domain) do
    sources =
      case message do
        %Expo.Message.Plural{} ->
          [IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgid_plural)]

        %Expo.Message.Singular{} ->
          [IO.iodata_to_binary(message.msgid)]
      end

    values =
      case message.msgstr do
        entries when is_map(entries) ->
          Enum.map(entries, fn {_index, value} -> IO.iodata_to_binary(value) end)

        value ->
          [IO.iodata_to_binary(value)]
      end

    invalid =
      Enum.any?(values, fn translated ->
        translated != "" and
          (placeholders(translated) != placeholders(hd(sources)) or
             (domain == "documentation" and
                not Marshall.LocalizedMarkdown.valid_translation?(hd(sources), translated)))
      end)

    if invalid, do: IO.puts("  INVALID translation structure: #{inspect(hd(sources))}")

    %{
      total: counts.total + 1,
      empty: counts.empty + if(Enum.any?(values, &(&1 == "")), do: 1, else: 0),
      source_equal: counts.source_equal + if(Enum.all?(values, &(&1 in sources)), do: 1, else: 0),
      invalid: counts.invalid + if(invalid, do: 1, else: 0),
      fuzzy: counts.fuzzy + if("fuzzy" in List.flatten(message.flags), do: 1, else: 0)
    }
  end

  @spec placeholders(String.t()) :: MapSet.t(String.t())
  defp placeholders(text), do: Regex.scan(~r/%\{[^}]+\}/, text) |> List.flatten() |> MapSet.new()
end

Marshall.LocaleCatalogCheck.run(System.argv())
