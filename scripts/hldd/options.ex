defmodule Overalls.HLDDOptions do
  @moduledoc "Stable Markdown for evaluated Overalls option declarations."
  @spec render(String.t()) :: String.t()
  def render(json) do
    entries = JSON.decode!(json)
    unless is_list(entries), do: raise("expected NixOS option list")

    body =
      entries
      |> Enum.sort_by(& &1["name"])
      |> Enum.map_join("\n", fn row ->
        unless is_map(row) and Enum.all?(~w(name type description), &is_binary(row[&1])),
          do: raise("invalid NixOS option declaration")

        "## `#{row["name"]}`\n\n#{row["description"]}\n\nType: `#{row["type"]}`.\n\n" <>
          value(
            "Default",
            row["default"],
            "Required when its service or enclosing record is selected."
          ) <>
          value("Example", row["example"], "")
      end)

    "# NixOS option reference\n\nGenerated from the default module's evaluated declarations. " <>
      "These are module defaults, not the running fleet configuration. `<name>` selects a named record; " <>
      "`*` selects a list element. Enable a service only after supplying its required configuration " <>
      "and satisfying its assertions. Package store hashes are omitted.\n\n" <>
      String.trim_trailing(body) <> "\n"
  end

  @spec value(String.t(), term(), String.t()) :: String.t()
  defp value(_label, nil, ""), do: ""
  defp value(label, nil, absent), do: "#{label}: #{absent}\n\n"

  defp value(label, %{"text" => text}, _) when is_binary(text) do
    stable = Regex.replace(~r"/nix/store/[a-z0-9]{32}-", text, "<store>/")
    "#{label}:\n\n```nix\n#{stable}\n```\n\n"
  end

  defp value(_, _, _), do: raise("expected a literal Nix option value")
end
