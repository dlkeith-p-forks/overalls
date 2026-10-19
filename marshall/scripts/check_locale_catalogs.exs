Code.require_file("locale_catalog_review.exs", __DIR__)

defmodule Marshall.LocaleCatalogCheck do
  @moduledoc "Enforces catalog completeness; --report-only diagnoses translation gaps without accepting them as coverage."
  @type counts :: %{
          total: non_neg_integer(),
          empty: non_neg_integer(),
          source_equal: non_neg_integer(),
          invalid: non_neg_integer(),
          fuzzy: non_neg_integer(),
          reviewed_source_equal: non_neg_integer(),
          unreviewed_source_equal_forms: non_neg_integer()
        }

  # @cc [owner:ghuntley,label:verification] catalog-coverage-honesty
  # Every policy locale MUST have every extracted domain. Empty and source-equal
  # entries and fuzzy flags MUST be reported separately; none establishes translated
  # coverage. Exact per-form reviews MAY satisfy invariant-text coverage, but MUST
  # remain separately counted. Default and --strict execution MUST reject non-English
  # gaps and fuzzy entries in every locale; only --report-only MAY report gaps
  # without failing. Structural errors and invalid reviews MUST always fail.
  # English empty/source-equal fallback MUST remain permitted. A copied plural
  # form MUST remain a strict gap. Duplicate or obsolete identities MUST never
  # silently mask messages.
  @spec run([String.t()]) :: :ok
  def run(args) do
    unless args in [[], ["--strict"], ["--report-only"]],
      do: raise(ArgumentError, "Expected no arguments, --strict, or --report-only")

    strict? = args != ["--report-only"]
    root = Path.expand("../priv/gettext", __DIR__)
    locales = Marshall.Localization.supported_locales()
    domains = Path.wildcard(Path.join(root, "*.pot"))

    if domains == [] or Enum.any?(domains, &(Path.basename(&1) == "default.pot")),
      do: raise("Expected feature-domain templates; default.pot is not permitted")

    expected_domains = domains |> Enum.map(&Path.basename(&1, ".pot")) |> Enum.sort()

    for locale <- locales do
      actual_domains =
        root
        |> Path.join("#{locale}/LC_MESSAGES/*.po")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".po"))
        |> Enum.sort()

      unless actual_domains == expected_domains,
        do: raise("Missing or unexpected feature-domain catalogs for #{locale}")
    end

    reviews =
      root
      |> Path.join("reviewed_source_equal.json")
      |> Marshall.LocaleCatalogReview.load!()
      |> Marshall.LocaleCatalogReview.for_app("marshall")

    results =
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

        {counts, observations} =
          Enum.reduce(
            catalog.messages,
            {%{
               total: 0,
               empty: 0,
               source_equal: 0,
               invalid: 0,
               fuzzy: 0,
               reviewed_source_equal: 0,
               unreviewed_source_equal_forms: 0
             }, %{}},
            fn message, {counts, observations} ->
              {next, forms} = count(message, counts, domain, locale, reviews)
              {next, Map.merge(observations, forms)}
            end
          )

        IO.puts(
          "#{locale}/#{domain}: total=#{counts.total} empty=#{counts.empty} source_equal=#{counts.source_equal} reviewed_source_equal=#{counts.reviewed_source_equal} unreviewed_source_equal_forms=#{counts.unreviewed_source_equal_forms} fuzzy=#{counts.fuzzy} invalid=#{counts.invalid}"
        )

        {if(locale == "en",
           do: 0,
           else: counts.empty + counts.unreviewed_source_equal_forms
         ) + counts.fuzzy, counts.invalid, observations}
      end

    observations = Enum.reduce(results, %{}, fn {_, _, forms}, acc -> Map.merge(acc, forms) end)
    Marshall.LocaleCatalogReview.validate!(reviews, observations)

    if Enum.any?(results, fn {_missing, invalid, _observations} -> invalid > 0 end),
      do: raise("Catalog placeholder or documentation structure errors remain")

    if strict? and
         Enum.any?(results, fn {missing, _invalid, _observations} -> missing > 0 end),
       do: raise("Untranslated catalog entries remain; see empty and source_equal counts above")

    :ok
  end

  @spec count(
          Expo.Message.t(),
          counts(),
          String.t(),
          String.t(),
          Marshall.LocaleCatalogReview.reviews()
        ) ::
          {counts(), Marshall.LocaleCatalogReview.observations()}
  defp count(message, counts, domain, locale, reviews) do
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
          Enum.map(entries, fn {index, value} -> {index, IO.iodata_to_binary(value)} end)

        value ->
          [{0, IO.iodata_to_binary(value)}]
      end

    invalid =
      Enum.any?(values, fn {_index, translated} ->
        translated != "" and
          (placeholders(translated) != placeholders(hd(sources)) or
             (domain == "documentation" and
                not Marshall.LocalizedMarkdown.valid_translation?(hd(sources), translated)))
      end)

    if invalid, do: IO.puts("  INVALID translation structure: #{inspect(hd(sources))}")

    fuzzy = "fuzzy" in List.flatten(message.flags)

    observations =
      Marshall.LocaleCatalogReview.observe("marshall", locale, domain, message, invalid)

    all_source_equal = Enum.all?(values, fn {_, value} -> value in sources end)
    unreviewed = Marshall.LocaleCatalogReview.unreviewed_forms(reviews, observations)

    {%{
       total: counts.total + 1,
       empty:
         counts.empty +
           if(Enum.any?(values, fn {_, value} -> String.trim(value) == "" end), do: 1, else: 0),
       source_equal:
         counts.source_equal +
           if(all_source_equal, do: 1, else: 0),
       invalid: counts.invalid + if(invalid, do: 1, else: 0),
       fuzzy: counts.fuzzy + if(fuzzy, do: 1, else: 0),
       reviewed_source_equal:
         counts.reviewed_source_equal + if(all_source_equal and unreviewed == 0, do: 1, else: 0),
       unreviewed_source_equal_forms: counts.unreviewed_source_equal_forms + unreviewed
     }, observations}
  end

  @spec placeholders(String.t()) :: MapSet.t(String.t())
  defp placeholders(text), do: Regex.scan(~r/%\{[^}]+\}/, text) |> List.flatten() |> MapSet.new()
end

Marshall.LocaleCatalogCheck.run(System.argv())
