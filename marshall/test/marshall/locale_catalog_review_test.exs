Code.require_file("../../scripts/locale_catalog_review.exs", __DIR__)

defmodule Marshall.LocaleCatalogReviewTest do
  use ExUnit.Case, async: true
  alias Marshall.LocaleCatalogReview, as: Review

  @spec record() :: %{String.t() => String.t() | non_neg_integer() | nil}
  defp record do
    %{
      "app" => "marshall",
      "locale" => "fi",
      "domain" => "default",
      "context" => nil,
      "msgid" => "CPU",
      "msgid_plural" => nil,
      "form" => 0,
      "reason" => "technical_literal",
      "note" => "Established Finnish processor abbreviation."
    }
  end

  @spec status() :: Review.observation()
  defp status, do: %{source_equal: true, fuzzy: false, invalid: false}

  test "exact reviewed form satisfies coverage while preserving raw observations" do
    reviews = Review.parse!([record()])
    [key] = Map.keys(reviews)
    observations = %{key => status()}
    assert :ok = Review.validate!(reviews, observations)
    assert Review.unreviewed_forms(reviews, observations) == 0
    assert observations[key].source_equal
    assert Review.unreviewed_forms(%{}, observations) == 1
  end

  test "every identity dimension is exact and cannot widen an exception" do
    reviews = Review.parse!([record()])
    [key] = Map.keys(reviews)

    for {field, value} <- [
          {"app", "porsche"},
          {"locale", "sv"},
          {"domain", "documentation"},
          {"context", ""},
          {"msgid", "GPU"},
          {"msgid_plural", "CPUs"},
          {"form", 1}
        ] do
      [different] = record() |> Map.put(field, value) |> then(&Review.parse!([&1])) |> Map.keys()
      assert Review.unreviewed_forms(reviews, %{different => status()}) == 1

      assert_raise ArgumentError, ~r/Stale or ineligible/, fn ->
        Review.validate!(reviews, %{different => status()})
      end

      refute different == key
    end
  end

  test "empty, changed, fuzzy, malformed and missing entries cannot use a review" do
    reviews = Review.parse!([record()])
    [key] = Map.keys(reviews)

    for observation <- [
          %{status() | source_equal: false},
          %{status() | fuzzy: true},
          %{status() | invalid: true}
        ] do
      assert_raise ArgumentError, ~r/Stale or ineligible/, fn ->
        Review.validate!(reviews, %{key => observation})
      end
    end

    assert_raise ArgumentError, ~r/Stale or ineligible/, fn -> Review.validate!(reviews, %{}) end
  end

  test "a reviewed plural form cannot hide another copied form or neighboring message" do
    reviewed = %{record() | "msgid_plural" => "CPUs"}
    reviews = Review.parse!([reviewed])
    [key] = Map.keys(reviews)
    copied_other_form = put_elem(key, 6, 1)
    translated_form = put_elem(key, 6, 2)
    neighbor = put_elem(key, 4, "GPU")

    observations = %{
      key => status(),
      copied_other_form => status(),
      neighbor => status(),
      translated_form => %{status() | source_equal: false}
    }

    assert :ok = Review.validate!(reviews, observations)
    assert Review.unreviewed_forms(reviews, observations) == 2
  end

  test "real plural messages detect copied forms even alongside a translated form" do
    message = %Expo.Message.Plural{
      msgid: ["CPU"],
      msgid_plural: ["CPUs"],
      msgstr: %{0 => ["CPU"], 1 => ["suorittimet"], 2 => [""]},
      msgctxt: nil,
      flags: []
    }

    observations = Review.observe("marshall", "fi", "default", message, false)
    assert Review.unreviewed_forms(%{}, observations) == 1
    assert observations[Review.identity("marshall", "fi", "default", message, 0)].source_equal
    refute observations[Review.identity("marshall", "fi", "default", message, 1)].source_equal
    refute observations[Review.identity("marshall", "fi", "default", message, 2)].source_equal

    assert Enum.all?(Review.observe("marshall", "fi", "default", message, true), fn {_, value} ->
             value.invalid
           end)

    fuzzy = %{message | flags: [["fuzzy"]]}

    assert Enum.all?(Review.observe("marshall", "fi", "default", fuzzy, false), fn {_, value} ->
             value.fuzzy
           end)
  end

  test "manifest rejects duplicate identities, unknown fields and invalid review data" do
    assert_raise ArgumentError, ~r/Duplicate/, fn -> Review.parse!([record(), record()]) end

    for malformed <- [
          Map.put(record(), "wildcard", true),
          Map.delete(record(), "context"),
          %{record() | "reason" => "all_technical"},
          %{record() | "note" => " "},
          %{record() | "form" => -1},
          %{record() | "context" => 42}
        ] do
      assert_raise ArgumentError, fn -> Review.parse!([malformed]) end
    end

    assert_raise ArgumentError, fn -> Review.parse!(%{}) end
  end

  test "checked-in Finnish reviews identify exactly the 24 inspected invariant messages" do
    path = Path.expand("../../priv/gettext/reviewed_source_equal.json", __DIR__)
    reviews = Review.load!(path)
    assert map_size(reviews) == 24

    catalog =
      Expo.PO.parse_file!(Path.expand("../../priv/gettext/fi/LC_MESSAGES/default.po", __DIR__))

    observations =
      Map.new(Enum.filter(catalog.messages, &match?(%Expo.Message.Singular{}, &1)), fn message ->
        key = Review.identity("marshall", "fi", "default", message, 0)
        equal = IO.iodata_to_binary(message.msgid) == IO.iodata_to_binary(message.msgstr)

        {key,
         %{source_equal: equal, fuzzy: "fuzzy" in List.flatten(message.flags), invalid: false}}
      end)

    assert :ok = Review.validate!(reviews, observations)
    assert Review.unreviewed_forms(reviews, observations) == 0

    assert Enum.all?(Map.keys(reviews), fn {app, locale, domain, context, _, plural, form} ->
             {app, locale, domain, context, plural, form} ==
               {"marshall", "fi", "default", nil, nil, 0}
           end)
  end
end
