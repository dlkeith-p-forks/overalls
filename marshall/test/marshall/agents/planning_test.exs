defmodule Marshall.Agents.PlanningTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Agents.Planning

  @spec questions() :: [map()]
  defp questions do
    [
      %{
        "id" => "storage",
        "header" => "Storage",
        "question" => "Which store should hold the records?",
        "options" => [
          %{"label" => "Database", "description" => "Share records between workers."},
          %{"label" => "Files", "description" => "Keep records in the workspace."}
        ]
      }
    ]
  end

  test "questions have unique stable identities and bounded distinct choices" do
    assert {:ok, [_]} = Planning.validate_questions(questions())
    assert {:error, :invalid_questions} = Planning.validate_questions([])
    assert {:error, :invalid_questions} = Planning.validate_questions(questions() ++ questions())
    [question] = questions()

    for bad <- [
          Map.put(question, "id", "not stable"),
          Map.put(question, "header", ""),
          Map.put(question, "question", String.duplicate("x", 4097)),
          Map.put(question, "options", []),
          Map.put(question, "options", List.duplicate(hd(question["options"]), 2)),
          Map.put(question, "extra", true)
        ] do
      assert {:error, :invalid_questions} = Planning.validate_questions([bad])
    end
  end

  test "all questions require a known selection or written alternative" do
    assert {:ok, %{"storage" => %{"selected" => "Database", "text" => ""}}} =
             Planning.validate_answers(questions(), %{"storage" => %{"selected" => "Database"}})

    assert {:ok, %{"storage" => %{"selected" => nil, "text" => "Use the existing service."}}} =
             Planning.validate_answers(questions(), %{
               "storage" => %{"text" => "Use the existing service."}
             })

    for bad <- [
          %{},
          %{"extra" => %{"text" => "answer"}},
          %{"storage" => %{}},
          %{"storage" => %{"selected" => "Missing"}},
          %{"storage" => %{"text" => "   "}},
          %{"storage" => %{"text" => String.duplicate("a", 16_385)}},
          %{"storage" => %{"selected" => "Database", "extra" => true}}
        ] do
      assert {:error, :invalid_answers} = Planning.validate_answers(questions(), bad)
    end
  end

  test "only a complete standalone proposal block is implementable" do
    assert {:ok, "# Plan\n\nMake the change and verify it."} =
             Planning.parse_proposal(
               "Ready.\n\n<proposed_plan>\n# Plan\n\nMake the change and verify it.\n</proposed_plan>"
             )

    assert {:ok, "Plan"} = Planning.parse_proposal("<proposed_plan>\r\nPlan\r\n</proposed_plan>")

    for text <- [
          "Some ideas without a proposal.",
          "<proposed_plan>\nIncomplete",
          "<proposed_plan>inline</proposed_plan>",
          "<proposed_plan>\n  \n</proposed_plan>",
          "<proposed_plan>\n<proposed_plan>\nNested\n</proposed_plan>\n</proposed_plan>",
          "<proposed_plan>\nOne\n</proposed_plan>\n<proposed_plan>\nTwo\n</proposed_plan>",
          "<proposed_plan>\n" <> String.duplicate("x", 60_001) <> "\n</proposed_plan>"
        ] do
      assert :none = Planning.parse_proposal(text)
    end
  end

  property "a prefix cut before the closing tag never grants an implementation identity" do
    check all(
            body <- string(:alphanumeric, min_length: 1, max_length: 300),
            suffix_size <- integer(0..15)
          ) do
      text = "<proposed_plan>\n" <> body <> "\n"
      closing_prefix = binary_part("</proposed_plan>", 0, suffix_size)
      assert :none = Planning.parse_proposal(text <> closing_prefix)
    end
  end

  test "mode instructions are application-selected and child planning cannot ask humans" do
    assert Planning.instructions(:plan) =~ "Do not modify project"
    assert Planning.instructions(:plan) =~ "not a separate filesystem permission boundary"
    assert Planning.instructions(:plan) =~ "request_user_input"
    assert Planning.instructions(:plan, child?: true) =~ "Do not ask the human"
    assert Planning.instructions(:work) =~ "Carry out the user's requested work"
    refute Planning.instructions(:work) =~ "Do not modify project"
    assert Planning.question_tool()["name"] == "request_user_input"
  end
end
