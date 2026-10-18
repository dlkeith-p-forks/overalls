defmodule Marshall.Accounts.User.Senders.SendMagicLinkEmail do
  @moduledoc "Queue a short-lived encrypted magic link; never return provider diagnostics."
  use AshAuthentication.Sender
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] email-request-nondisclosure
  # The authentication sender MUST return the same success shape after enqueue
  # success or failure, and log only a fixed failure event without recipient,
  # token, provider response or exception details.
  @impl true
  def send(user_or_email, token, _) do
    email =
      case user_or_email do
        %{email: email} -> to_string(email)
        email -> to_string(email)
      end

    override = if is_map(user_or_email), do: Map.get(user_or_email, :locale)
    locale = Marshall.Localization.choose(override, Gettext.get_locale(MarshallWeb.Gettext), nil)

    result =
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        Marshall.Accounts.AuthEmails.enqueue(email, token)
      end)

    case result do
      :ok -> :ok
      {:error, _} -> Marshall.Events.emit("mail.enqueue_failed", [])
    end

    :ok
  end
end
