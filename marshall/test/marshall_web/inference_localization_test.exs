defmodule MarshallWeb.InferenceLocalizationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "Japanese and Arabic usage rows translate finite statuses and missing token data" do
    outcomes = [
      {"completed", "Completed"},
      {"upstream_error", "Upstream error"},
      {"cancelled", "Cancelled"},
      {"revoked", "Revoked"},
      {"transport_error", "Transport error"},
      {"interrupted", "Interrupted"}
    ]

    for locale <- ["ja", "ar"] do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        unknown = translated("Unknown")

        rows =
          [row("missing", nil), row("missing-fields", %{"tokens" => %{}})] ++
            Enum.with_index(outcomes, fn {outcome, _}, index ->
              row("known-#{index}", %{
                "outcome" => outcome,
                "completeness" => "complete",
                "tokens" => %{"input_tokens" => 17}
              })
            end) ++
            [
              row("partial", %{
                "outcome" => "unexpected-value",
                "completeness" => "partial",
                "tokens" => %{}
              })
            ]

        document = render_usage(rows) |> Floki.parse_document!()

        for id <- ["missing", "missing-fields"] do
          cells = Floki.find(document, "#usage-#{id} > td")
          assert cells |> Enum.at(2) |> Floki.text() == unknown
          assert cells |> Enum.at(3) |> Floki.text() == unknown
          assert cells |> Enum.at(5) |> Floki.text() =~ unknown
        end

        assert Floki.find(document, "#usage-missing > td")
               |> Enum.at(4)
               |> Floki.text()
               |> String.trim() == translated("Unreported")

        assert Floki.find(document, "#usage-missing-fields > td")
               |> Enum.at(4)
               |> Floki.text()
               |> String.trim() == unknown

        for {{_, source}, index} <- Enum.with_index(outcomes) do
          cells = Floki.find(document, "#usage-known-#{index} > td")
          assert cells |> Enum.at(2) |> Floki.text() == "17"
          assert cells |> Enum.at(3) |> Floki.text() == unknown
          assert cells |> Enum.at(4) |> Floki.text() |> String.trim() == translated(source)
          assert cells |> Enum.at(5) |> Floki.text() =~ translated("Complete")
        end

        assert Floki.find(document, "#usage-partial > td")
               |> Enum.at(4)
               |> Floki.text()
               |> String.trim() == unknown

        assert Floki.find(document, "#usage-partial > td") |> Enum.at(5) |> Floki.text() =~
                 translated("Partial")

        refute Floki.text(document) =~ "unexpected-value"
      end)
    end
  end

  @spec translated(String.t()) :: String.t()
  defp translated(source) do
    text = Gettext.dgettext(MarshallWeb.Gettext, "inference", source)
    refute text == source
    text
  end

  @spec row(String.t(), map() | nil) :: map()
  defp row(id, completion) do
    %{
      id: id,
      completion: completion,
      inserted_at: nil,
      model: "model-id",
      provider: "openai",
      vm_id: "machine-id",
      placement_id: "placement-id",
      execution_epoch: 1
    }
  end

  @spec render_usage([map()]) :: String.t()
  defp render_usage(rows) do
    render_component(&MarshallWeb.InferenceLive.render/1,
      flash: %{},
      current_user: %{email: "test@example.test"},
      time_zone: nil,
      now: nil,
      live_action: :index,
      filters: %{},
      totals: %{},
      chart: [],
      empty?: false,
      next: nil,
      form: Phoenix.Component.to_form(%{"provider" => "", "model" => ""}, as: :filter),
      streams: %{usage: Enum.map(rows, &{"usage-#{&1.id}", &1})}
    )
  end
end
