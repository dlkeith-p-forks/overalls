defmodule PackagedLocalizationPreference do
  @spec run() :: :ok
  def run do
    {:ok, _} = Application.ensure_all_started(:marshall)
    locale = System.fetch_env!("LOCALIZATION_TEST_LOCALE")
    true = locale in Marshall.Localization.supported_locales()

    [owner] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.User, email: "language-owner@example.test")

    {:ok, _} =
      Marshall.Accounts.User
      |> Ash.ActionInput.for_action(:set_locale, %{locale: locale}, actor: owner)
      |> Ash.run_action()

    :ok
  end
end

PackagedLocalizationPreference.run()
