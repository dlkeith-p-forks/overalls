defmodule Marshall.Accounts.AuthEmails do
  @moduledoc "Durable magic-link delivery and a shared per-recipient one-minute cooldown."
  alias AshAuthentication.{Jwt, TokenResource.Actions}
  alias Marshall.Accounts.{AuthEmail, EmailAddress, Token, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query

  # @cc [owner:ghuntley,label:security] email-recipient-token-binding
  # Enqueue MUST accept only a currently stored, unexpired magic-link token whose
  # signed identity matches the validated recipient case-insensitively. Invalid
  # inputs or failures MUST return only mail_enqueue_failed without token details.
  @spec enqueue(String.t(), String.t()) :: :ok | {:error, :mail_enqueue_failed}
  def enqueue(email, token) do
    Marshall.Mailer.LogFilter.private(fn ->
      with true <- EmailAddress.valid?(email),
           {:ok, claims, User} <- Jwt.verify(token, User),
           true <-
             claims["act"] == "sign_in_with_magic_link" and is_binary(claims["identity"]) and
               String.downcase(claims["identity"]) == String.downcase(email),
           {:ok, [stored]} <-
             Actions.get_token(Token, %{"jti" => claims["jti"], "purpose" => "magic_link"}),
           true <- DateTime.compare(stored.expires_at, Ledger.now()) == :gt,
           {:ok, _} <- insert(email, token, stored.expires_at) do
        :ok
      else
        _ -> {:error, :mail_enqueue_failed}
      end
    end)
  rescue
    _ -> {:error, :mail_enqueue_failed}
  catch
    _, _ -> {:error, :mail_enqueue_failed}
  end

  # @cc [owner:ghuntley,label:concurrency] email-shared-cooldown-and-job
  # Outbox insertion and its delivery job MUST commit together. Across nodes,
  # case-insensitive recipients share a one-minute cooldown and a token may have
  # only one delivery record; suppressed requests MUST return success without
  # another job. Recipient fingerprints MUST be keyed rather than plain hashes.
  defp insert(email, token, expires_at) do
    key = Application.fetch_env!(:marshall, :token_signing_secret)

    recipient =
      :crypto.mac(:hmac, :sha256, key, String.downcase(email)) |> Base.encode16(case: :lower)

    fingerprint = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    Ash.transact(AuthEmail, fn ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["auth-email:" <> recipient],
        log: false
      )

      cutoff = DateTime.add(Ledger.now(), -60, :second)

      recent =
        AuthEmail
        |> Ash.Query.filter(recipient_fingerprint == ^recipient and inserted_at > ^cutoff)
        |> Ash.Query.limit(1)
        |> Ash.read!(actor: SystemActor.compute())

      if recent == [] and Ledger.read!(AuthEmail, token_fingerprint: fingerprint) == [] do
        Ledger.create!(AuthEmail, :enqueue, %{
          payload: %{
            "email" => email,
            "token" => token,
            "locale" =>
              Marshall.Localization.normalize(Gettext.get_locale(MarshallWeb.Gettext)) || "en"
          },
          token_fingerprint: fingerprint,
          recipient_fingerprint: recipient,
          expires_at: expires_at
        })
      end

      :ok
    end)
  end
end
