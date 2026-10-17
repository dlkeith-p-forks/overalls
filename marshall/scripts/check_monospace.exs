# Structural gate for the Monospace Web presentation (ADR-0161).
#
# Fails when application templates carry utility-framework classes, when a
# stylesheet declares a colour outside the token file, when any stylesheet,
# script or template references an external resource, or when JavaScript
# toggles layout utility classes. Run from the Marshall directory:
#
#     elixir scripts/check_monospace.exs
#
# Passing proves the absence of these patterns, not the visual result; the
# browser probe (scripts/monospace_browser_probe.py) measures rendering.
defmodule Marshall.MonospaceCheck do
  @moduledoc false

  @type finding :: {Path.t(), pos_integer(), String.t()}

  @utility_tokens ~r/(?:^|[\s"\[])(?:dark|md|sm|lg|xl|hover|focus|group-hover|motion-safe):|(?:^|[\s"\[])(?:rounded|px|py|pt|pb|pl|pr|m[tblrxy]?|gap|space-[xy]|text|bg|border|shadow|opacity|size|w|h|min-w|max-w|grid-cols|leading|tracking)-[\w\[\]\/.%-]+|(?:^|[\s"\[])(?:flex|flex-1|items-\w+|justify-\w+|truncate|shrink-0|font-(?:semibold|medium|bold|mono)|tabular-nums|animate-\w+|transition|uppercase|divide-y)(?:$|[\s"\]])/
  @allowed_classes %{"lib/marshall_web/live/agent_cli_approval_live.ex" => ["font-mono"]}
  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(|color-mix\(/
  @colour_allowed ["assets/css/tokens.css", "assets/css/print.css"]
  @colour_allowed_lines [
    "rgba(0, 0, 0, .6)",
    "color-mix(in srgb, var(--text-color) 10%, var(--background-color) 90%)"
  ]
  @remote_resource ~r/url\(\s*['"]?https?:|(?:src|href)=["']https?:\/\/[^"']*\.(?:css|js|mjs|woff2?|ttf|otf)\b|@import\s+url\(['"]?https?:/
  @js_utility_toggle ~r/classList\.\w+\(\s*"(?:opacity-|h-|w-|bg-|text-|p[xy]?-|m[xy]?-|rounded|flex|hidden-)/

  @spec run() :: :ok
  def run do
    findings =
      template_findings() ++ colour_findings() ++ external_findings() ++ js_findings()

    case findings do
      [] ->
        IO.puts("Monospace presentation check passed")

      findings ->
        Enum.each(findings, fn {path, line, message} ->
          IO.puts(:stderr, "#{path}:#{line}: #{message}")
        end)

        System.halt(1)
    end
  end

  @spec template_findings() :: [finding()]
  defp template_findings do
    for path <- files(["lib/marshall_web/**/*.ex", "lib/marshall_web/**/*.heex"]),
        {line, number} <- numbered(path),
        match <- class_values(line),
        token <- String.split(match),
        not allowed?(path, token),
        Regex.match?(@utility_tokens, " " <> token <> " ") do
      {path, number, "utility class `#{token}` in template"}
    end
  end

  @spec colour_findings() :: [finding()]
  defp colour_findings do
    for path <- files(["assets/css/*.css"]),
        path not in @colour_allowed,
        {line, number} <- numbered(path),
        Regex.match?(@colour_literal, line),
        not Enum.any?(@colour_allowed_lines, &String.contains?(line, &1)) do
      {path, number, "colour literal outside tokens.css"}
    end
  end

  @spec external_findings() :: [finding()]
  defp external_findings do
    for path <-
          files([
            "assets/css/*.css",
            "assets/js/**/*.js",
            "lib/marshall_web/**/*.ex",
            "lib/marshall_web/**/*.heex"
          ]),
        {line, number} <- numbered(path),
        Regex.match?(@remote_resource, line) do
      {path, number, "external stylesheet, script or font reference"}
    end
  end

  @spec js_findings() :: [finding()]
  defp js_findings do
    for path <- files(["assets/js/**/*.js"]),
        {line, number} <- numbered(path),
        Regex.match?(@js_utility_toggle, line) do
      {path, number, "JavaScript toggles a utility class"}
    end
  end

  @spec files([String.t()]) :: [Path.t()]
  defp files(globs), do: globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.sort()

  @spec numbered(Path.t()) :: [{String.t(), pos_integer()}]
  defp numbered(path), do: path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

  @spec class_values(String.t()) :: [String.t()]
  defp class_values(line) do
    ~r/class=(?:"([^"]*)"|\{\[([^\]]*)\]\}|\{"([^"]*)"\})/
    |> Regex.scan(line)
    |> Enum.flat_map(fn groups ->
      groups
      |> Enum.drop(1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.replace(&1, ~r/[",&&]/, " "))
    end)
  end

  @spec allowed?(Path.t(), String.t()) :: boolean()
  defp allowed?(path, token), do: token in Map.get(@allowed_classes, path, [])
end

Marshall.MonospaceCheck.run()
