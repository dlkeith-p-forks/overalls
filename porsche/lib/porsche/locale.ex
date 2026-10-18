defmodule Porsche.Locale do
  @moduledoc "Validated display locale from Marshall's authenticated session."

  @spec from_session(term()) :: String.t()
  def from_session(%{"user" => %{"locale" => locale}}) do
    if OverallsProtocol.SSHManagement.locale?(locale), do: locale, else: "en"
  end

  def from_session(_), do: "en"

  @spec put_locale(term()) :: :ok
  def put_locale(session) do
    locale = from_session(session)
    Gettext.put_locale(Porsche.Gettext, locale)
    Localize.put_locale(locale)
    :ok
  end
end
