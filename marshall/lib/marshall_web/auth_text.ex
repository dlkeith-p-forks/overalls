defmodule MarshallWeb.AuthText do
  @moduledoc """
  Copy for AshAuthentication's generated sign-in views. The library derives
  button labels from action names, so this translation hook replaces them with
  plain-language text and interpolates bindings for everything else.
  """

  use Gettext, backend: MarshallWeb.Gettext

  @spec translate(String.t(), keyword() | map()) :: String.t()
  def translate(msgid, bindings) when is_binary(msgid) do
    case msgid do
      "Request magic link" ->
        dgettext("auth", "Email me a sign-in link", bindings)

      "Requesting ..." ->
        dgettext("auth", "Sending link…", bindings)

      "Sign in" ->
        dgettext("auth", "Sign in", bindings)

      "Email" ->
        dgettext("auth", "Email", bindings)

      "Remember me" ->
        dgettext("auth", "Remember me", bindings)

      "Check your email for a sign-in link. Your account will be created automatically when you sign in." ->
        dgettext(
          "auth",
          "Check your email for a sign-in link. Your account will be created automatically when you sign in.",
          bindings
        )

      _ ->
        Gettext.dgettext(MarshallWeb.Gettext, "auth", msgid, bindings)
    end
  end
end
