defmodule MarshallWeb.ThreadCommandsTest do
  use ExUnit.Case, async: true

  alias MarshallWeb.ThreadCommands

  test "Japanese and Arabic command labels localize without changing slash tokens" do
    english = Gettext.with_locale(MarshallWeb.Gettext, "en", &ThreadCommands.all/0)

    for locale <- ["ja", "ar"] do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        assert Enum.map(ThreadCommands.all(), &elem(&1, 0)) == Enum.map(english, &elem(&1, 0))

        for {{command, label, description}, {command, source_label, source_description}} <-
              Enum.zip(ThreadCommands.all(), english) do
          refute label == source_label
          refute description == source_description
          assert ThreadCommands.parse("/#{command}") == {:command, command, ""}
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:verification;product] composer-literal-prefix-evidence
  # Slash-looking text with leading whitespace MUST retain its exact content;
  # recognizing commands MUST NOT trim literal prompts into operations.
  test "literal prompts retain whitespace and embedded command-looking text" do
    for text <- [
          " /compact",
          "\t/plan",
          "\n/work implement",
          "Explain /share",
          "",
          "$review fix this"
        ] do
      assert ThreadCommands.parse(text) == {:prompt, text}
    end
  end

  test "plan and work can carry a task without changing its internal spacing" do
    assert ThreadCommands.parse("/plan") == {:command, :plan, ""}

    assert ThreadCommands.parse("/work  Fix the  build\nthen verify  ") ==
             {:command, :work, "Fix the  build\nthen verify"}

    assert ThreadCommands.parse("/plan\nInvestigate first") ==
             {:command, :plan, "Investigate first"}
  end

  test "unknown names and unsupported arguments are explicit refusals" do
    for text <- ["/", "/unknown", "/WORK", "/plan-more", "/plan/task"] do
      assert ThreadCommands.parse(text) == {:error, :unknown_command}
    end

    for {command, _, _} <- ThreadCommands.all(), command not in [:plan, :work] do
      assert ThreadCommands.parse("/#{command}") == {:command, command, ""}
      assert ThreadCommands.parse("/#{command} unintended task") == {:error, :command_arguments}
    end
  end
end
