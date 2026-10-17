defmodule Marshall.Agents.WebSearchTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Agents.{ModelProtocol, WebSearch}

  property "the projection includes every organic result in provider order" do
    check all(
            titles <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 32), max_length: 50)
          ) do
      organic =
        Enum.with_index(titles, fn title, index ->
          %{"title" => title, "link" => "https://example.org/#{index}", "snippet" => "summary"}
        end)

      assert {:ok, %{"results" => results, "answer_box" => nil}, 1} =
               WebSearch.project(%{"organic" => organic, "credits" => 1})

      assert Enum.map(results, & &1["title"]) == titles
      assert length(results) == length(organic)
    end
  end

  property "cache keys preserve exact trimmed query bytes" do
    check all(query <- string(:printable, min_length: 1, max_length: 200)) do
      assert WebSearch.cache_key("  " <> query <> "  ") == WebSearch.cache_key(query)
      assert byte_size(WebSearch.cache_key(query)) == 64
    end
  end

  test "web search has no tool-specific 2000-byte limit" do
    query = String.duplicate("a", 3_000)

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "search-1",
          "name" => "web_search",
          "arguments" => Jason.encode!(%{"query" => query})
        }
      ]
    }

    assert {:ok, {:tools, [%{tool: :web_search, arguments: %{"query" => ^query}}]}} =
             ModelProtocol.parse_response(response, :standard)
  end

  test "oversized complete projections fail instead of losing results" do
    organic = [
      %{
        "title" => "large",
        "link" => "https://example.org",
        "snippet" => String.duplicate("x", 200_000)
      }
    ]

    assert {:error, :search_result_too_large} = WebSearch.project(%{"organic" => organic})
  end
end
