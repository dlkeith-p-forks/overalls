defmodule MarshallWeb.AuthText do
  @moduledoc """
  Copy for AshAuthentication's generated sign-in views. The library derives
  button labels from action names, so this translation hook replaces them with
  plain-language text and interpolates bindings for everything else.
  """

  @replacements %{
    "Request magic link" => "Email me a sign-in link",
    "Requesting ..." => "Sending link…"
  }

  @spec translate(String.t(), keyword() | map()) :: String.t()
  def translate(msgid, bindings) when is_binary(msgid) do
    text = Map.get(@replacements, msgid, msgid)

    Enum.reduce(bindings, text, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
