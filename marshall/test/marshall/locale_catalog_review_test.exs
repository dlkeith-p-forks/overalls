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

  test "application scope retains its own exact reviews and rejects unknown names" do
    reviews = Review.parse!([record(), %{record() | "app" => "porsche"}])
    marshall = Review.for_app(reviews, "marshall")
    porsche = Review.for_app(reviews, "porsche")
    assert map_size(marshall) == 1
    assert map_size(porsche) == 1
    assert Map.merge(marshall, porsche) == reviews

    [porsche_key] = Map.keys(porsche)
    assert :ok = Review.validate!(porsche, %{porsche_key => status()})

    assert_raise ArgumentError, ~r/Stale or ineligible/, fn ->
      Review.validate!(porsche, %{})
    end

    assert_raise ArgumentError, ~r/Unknown.*application/, fn ->
      Review.for_app(reviews, "porcshe")
    end
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
          %{record() | "app" => "porcshe"},
          %{record() | "form" => -1},
          %{record() | "context" => 42}
        ] do
      assert_raise ArgumentError, fn -> Review.parse!([malformed]) end
    end

    assert_raise ArgumentError, fn -> Review.parse!(%{}) end
  end

  test "checked-in Marshall reviews identify exact present feature-catalog forms" do
    root = Path.expand("../../priv/gettext", __DIR__)

    reviews =
      root
      |> Path.join("reviewed_source_equal.json")
      |> Review.load!()
      |> Review.for_app("marshall")

    assert map_size(reviews) > 0

    observations =
      root
      |> Path.join("*/LC_MESSAGES/*.po")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, observations ->
        locale = path |> Path.dirname() |> Path.dirname() |> Path.basename()
        domain = Path.basename(path, ".po")

        Enum.reduce(Expo.PO.parse_file!(path).messages, observations, fn message, observations ->
          Map.merge(observations, Review.observe("marshall", locale, domain, message, false))
        end)
      end)

    assert :ok = Review.validate!(reviews, observations)

    assert Enum.all?(Map.keys(reviews), fn {app, _, domain, _, _, _, _} ->
             app == "marshall" and domain != "default"
           end)
  end
end
