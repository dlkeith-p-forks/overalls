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
      "Request magic link" -> gettext("Email me a sign-in link", bindings)
      "Requesting ..." -> gettext("Sending link…", bindings)
      "Sign in" -> gettext("Sign in", bindings)
      "Email" -> gettext("Email", bindings)
      "Remember me" -> gettext("Remember me", bindings)
      "Check your email for a sign-in link. Your account will be created automatically when you sign in." ->
        gettext("Check your email for a sign-in link. Your account will be created automatically when you sign in.", bindings)
      _ -> Gettext.gettext(MarshallWeb.Gettext, msgid, bindings)
    end
  end
end
