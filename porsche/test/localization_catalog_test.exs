Code.require_file("../../marshall/scripts/locale_catalog_review.exs", __DIR__)

defmodule Porsche.LocalizationCatalogTest do
  use ExUnit.Case, async: true
  alias Marshall.LocaleCatalogReview, as: Review

  @locales ~w(en zh-Hans hi es ar fr bn pt-BR pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv arz sw ha)

  test "every supported locale covers the extracted terminal messages with matching placeholders" do
    domains = ~w(help management onboarding sessions)
    root = :porsche |> :code.priv_dir() |> Path.join("gettext")
    templates = Path.wildcard(Path.join(root, "*.pot")) |> Enum.map(&Path.basename(&1, ".pot"))
    assert Enum.sort(templates) == domains

    for locale <- @locales do
      catalogs =
        root
        |> Path.join(Path.join([locale, "LC_MESSAGES", "*.po"]))
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".po"))

      assert Enum.sort(catalogs) == domains

      for domain <- domains do
        sources = messages(domain <> ".pot")
        translated = messages(Path.join([locale, "LC_MESSAGES", domain <> ".po"]))
        assert Map.keys(translated) |> Enum.sort() == Map.keys(sources) |> Enum.sort()

        for {source, target} <- translated do
          refute String.trim(target) == ""
          assert placeholders(source) == placeholders(target)
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification] porsche-catalog-exact-review-coverage
  # Every non-English source-equal form MUST have an exact eligible Porsche
  # review. Empty, fuzzy, invalid and stale forms MUST fail independently.
  test "exact invariant reviews cannot hide terminal catalog gaps or stale records" do
    reviews =
      "../../marshall/priv/gettext/reviewed_source_equal.json"
      |> Path.expand(__DIR__)
      |> Review.load!()
      |> Review.for_app("porsche")

    observations =
      for locale <- @locales,
          domain <- ~w(help management onboarding sessions),
          reduce: %{} do
        observations ->
          messages = catalog_messages(Path.join([locale, "LC_MESSAGES", domain <> ".po"]))
          identities = Enum.map(messages, &Expo.Message.key/1)
          assert MapSet.size(MapSet.new(identities)) == length(identities)

          Enum.reduce(messages, observations, fn message, observations ->
            refute message.obsolete
            refute "fuzzy" in List.flatten(message.flags)
            source = IO.iodata_to_binary(message.msgid)

            for {_form, target} <- values(message) do
              refute String.trim(target) == ""
              assert placeholders(source) == placeholders(target)
            end

            Map.merge(observations, Review.observe("porsche", locale, domain, message, false))
          end)
      end

    assert :ok = Review.validate!(reviews, observations)

    non_english =
      Map.reject(observations, fn {{_, locale, _, _, _, _, _}, _status} -> locale == "en" end)

    assert Review.unreviewed_forms(reviews, non_english) == 0
  end

  test "human command guidance preserves executable command tokens in every locale" do
    for locale <- @locales,
        {domain, source, command} <- [
          {"management", "Invalid command. Type help to see available commands.", "help"},
          {"management", "The owner has this machine pinned; unpin it first: unpin MACHINE",
           "unpin MACHINE"},
          {"sessions", "Porsche machine management. Type help.", "help"}
        ] do
      catalog = messages(Path.join([locale, "LC_MESSAGES", domain <> ".po"]))
      assert Map.fetch!(catalog, source) =~ command
    end
  end

  test "shared help descriptions stay in the extraction inventory" do
    summaries = OverallsProtocol.SSHCommand.catalog() |> Enum.map(& &1.summary) |> Enum.sort()
    assert Enum.sort(Porsche.SSH.CommandMessages.sources()) == summaries
  end

  test "Japanese human errors are translated and JSON remains language neutral" do
    Gettext.put_locale(Porsche.Gettext, "ja")
    response = %{"version" => 1, "status" => "error", "error" => "invalid_command"}
    assert Porsche.SSH.Output.render(response, false) =~ "無効なコマンド"
    assert JSON.decode!(Porsche.SSH.Output.render(response, true)) == response
  end

  test "dynamic help descriptions resolve through the help domain" do
    response = %{
      "result" => %{
        "commands" => [%{"usage" => "help", "summary" => "Show command help."}]
      }
    }

    Gettext.with_locale(Porsche.Gettext, "ja", fn ->
      translated = Gettext.dgettext(Porsche.Gettext, "help", "Show command help.")
      refute translated == "Show command help."
      assert Porsche.SSH.Output.render(response, false) == "help\n  " <> translated <> "\n"
      assert JSON.decode!(Porsche.SSH.Output.render(response, true)) == response
    end)
  end

  @spec messages(String.t()) :: %{String.t() => String.t()}
  defp messages(path) do
    path
    |> catalog_messages()
    |> Map.new(fn %Expo.Message.Singular{msgid: source, msgstr: target} ->
      {IO.iodata_to_binary(source), IO.iodata_to_binary(target)}
    end)
  end

  @spec catalog_messages(String.t()) :: [Expo.Message.t()]
  defp catalog_messages(path) do
    :porsche
    |> :code.priv_dir()
    |> Path.join("gettext")
    |> Path.join(path)
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
  end

  @spec values(Expo.Message.t()) :: [{non_neg_integer(), String.t()}]
  defp values(%Expo.Message.Singular{msgstr: value}), do: [{0, IO.iodata_to_binary(value)}]

  defp values(%Expo.Message.Plural{msgstr: forms}),
    do: Enum.map(forms, fn {index, value} -> {index, IO.iodata_to_binary(value)} end)

  @spec placeholders(String.t()) :: [String.t()]
  defp placeholders(message),
    do: Regex.scan(~r/%\{[^}]+\}/, message) |> List.flatten() |> Enum.sort()
end
