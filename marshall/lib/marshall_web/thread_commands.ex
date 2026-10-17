defmodule MarshallWeb.ThreadCommands do
  @moduledoc "Bounded composer commands, parsed before whitespace normalization."

  @type command ::
          :plan | :work | :compact | :skills | :context | :terminal | :code | :share | :help
  @type parsed ::
          {:prompt, String.t()}
          | {:command, command(), String.t()}
          | {:error, :unknown_command | :command_arguments}

  @commands [
    {:plan, "Plan", "Explore the task and agree on a plan"},
    {:work, "Work", "Implement and verify changes"},
    {:compact, "Compact context", "Summarize older context for the next turn"},
    {:skills, "Skills", "Choose or manage reusable instructions"},
    {:context, "Context", "Inspect the working directory and loaded sources"},
    {:terminal, "Open terminal", "Open this thread's machine terminal"},
    {:code, "Open VS Code", "Open the editor for this thread's machine"},
    {:share, "Share", "Manage access to the thread and its machine"},
    {:help, "Command help", "Learn the composer shortcuts"}
  ]

  @spec all() :: [{command(), String.t(), String.t()}]
  def all, do: @commands

  # @cc [owner:ghuntley,label:product;security] literal-prefix-command-parsing
  # Only a slash at byte zero MUST invoke commands. Unknown commands and
  # arguments to commands other than plan/work MUST refuse without admitting a
  # prompt; leading whitespace MUST preserve slash-looking text literally.
  @spec parse(String.t()) :: parsed()
  def parse("/" <> rest) do
    [name | tail] = String.split(rest, ~r/\s+/, parts: 2)
    argument = tail |> List.first("") |> String.trim()

    case Enum.find(@commands, fn {command, _, _} -> Atom.to_string(command) == name end) do
      nil -> {:error, :unknown_command}
      {command, _, _} when command in [:plan, :work] -> {:command, command, argument}
      {command, _, _} when argument == "" -> {:command, command, ""}
      _ -> {:error, :command_arguments}
    end
  end

  def parse(text) when is_binary(text), do: {:prompt, text}
end
