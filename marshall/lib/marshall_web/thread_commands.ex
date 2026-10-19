defmodule MarshallWeb.ThreadCommands do
  @moduledoc "Bounded composer commands, parsed before whitespace normalization."

  use Gettext, backend: MarshallWeb.Gettext

  @type command ::
          :plan | :work | :compact | :skills | :context | :terminal | :code | :share | :help
  @type parsed ::
          {:prompt, String.t()}
          | {:command, command(), String.t()}
          | {:error, :unknown_command | :command_arguments}

  @commands [
    {:plan, dgettext_noop("agents", "Plan"),
     dgettext_noop("agents", "Explore the task and agree on a plan")},
    {:work, dgettext_noop("agents", "Work"),
     dgettext_noop("agents", "Implement and verify changes")},
    {:compact, dgettext_noop("agents", "Compact context"),
     dgettext_noop("agents", "Summarize older context for the next turn")},
    {:skills, dgettext_noop("agents", "Skills"),
     dgettext_noop("agents", "Choose or manage reusable instructions")},
    {:context, dgettext_noop("agents", "Context"),
     dgettext_noop("agents", "Inspect the working directory and loaded sources")},
    {:terminal, dgettext_noop("agents", "Open terminal"),
     dgettext_noop("agents", "Open this thread's machine terminal")},
    {:code, dgettext_noop("agents", "Open VS Code"),
     dgettext_noop("agents", "Open the editor for this thread's machine")},
    {:share, dgettext_noop("agents", "Share"),
     dgettext_noop("agents", "Manage access to the thread and its machine")},
    {:help, dgettext_noop("agents", "Command help"),
     dgettext_noop("agents", "Learn the composer shortcuts")}
  ]

  @spec all() :: [{command(), String.t(), String.t()}]
  # @cc [owner:ghuntley,label:product] localized-command-presentation
  # Labels and descriptions MUST follow the current locale, while command atoms
  # and slash-command parsing MUST remain language-neutral.
  def all do
    Enum.map(@commands, fn {command, label, description} ->
      {command, Gettext.dgettext(MarshallWeb.Gettext, "agents", label),
       Gettext.dgettext(MarshallWeb.Gettext, "agents", description)}
    end)
  end

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
