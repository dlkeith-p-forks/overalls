defmodule Marshall.Accounts.DeliverAuthEmail do
  @moduledoc "Serialized, bounded delivery of a still-valid token; no provider diagnostics escape."
  use Ash.Resource.Change
  use MarshallWeb, :verified_routes
  use Gettext, backend: MarshallWeb.Gettext
  require Marshall.Events
  import Swoosh.Email
  alias Marshall.Accounts.{AuthEmail, Token, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  @message_id_domain "overalls.invalid"

  # @cc [owner:ghuntley,label:concurrency] email-delivery-locked-recheck
  # Delivery MUST reread and lock the outbox row inside the action transaction,
  # keeping the lock through SMTP and status update. Duplicate workers MUST NOT
  # send records already marked delivered/expired, and expired/consumed tokens
  # MUST be discarded without sending.

  # @cc [owner:ghuntley,label:observability] mail-outcome-after-commit
  # The delivery attempt event MUST be emitted only after the enclosing action
  # transaction commits or rolls back, and MUST reflect the committed terminal
  # status (or the failure that prevented one); an in-flight SMTP result MUST
  # never be reported as the committed outcome.
  @impl true
  def change(changeset, _, _) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Marshall.Mailer.LogFilter.private(fn ->
        # AshOban's initial read happens before this action transaction. Re-read
        # under a lock that remains held through SMTP and the final status write.
        if Marshall.Repo.in_transaction?() do
          case Ledger.lock!(AuthEmail, changeset.data.id) do
            nil -> Ash.Changeset.add_error(changeset, "Mail delivery no longer exists")
            record -> deliver(%{changeset | data: record})
          end
        else
          Ash.Changeset.add_error(changeset, "Mail delivery requires a transaction")
        end
      end)
    end)
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      unless Marshall.Repo.in_transaction?() do
        Marshall.Events.emit("mail.delivery_attempt",
          delivery_id: changeset.data.id,
          delivery_status: outcome(result)
        )
      end

      result
    end)
  end

  defp deliver(changeset) do
    record = changeset.data

    cond do
      record.status != :pending ->
        changeset

      DateTime.compare(record.expires_at, Ledger.now()) != :gt ->
        finish(changeset, :expired)

      true ->
        case payload(record) do
          {:ok, email, token, locale} ->
            if valid_token?(token) do
              case send_bounded(email, token, record.id, locale) do
                :ok -> finish(changeset, :delivered)
                :error -> failed(changeset)
              end
            else
              finish(changeset, :expired)
            end

          :error ->
            failed(changeset)
        end
    end
  end

  defp payload(record) do
    case Ash.load!(record, :payload, actor: SystemActor.compute()).payload do
      %{"email" => email, "token" => token} = payload when is_binary(email) and is_binary(token) ->
        locale = Marshall.Localization.normalize(payload["locale"]) || "en"
        {:ok, email, token, locale}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp valid_token?(token) do
    with {:ok, %{"act" => "sign_in_with_magic_link", "jti" => jti}, User} <-
           AshAuthentication.Jwt.verify(token, User),
         {:ok, [stored]} <-
           AshAuthentication.TokenResource.Actions.get_token(
             Token,
             %{"jti" => jti, "purpose" => "magic_link"}
           ) do
      DateTime.compare(stored.expires_at, Ledger.now()) == :gt
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:recovery] email-bounded-external-attempt
  # An SMTP attempt MUST have a ten-second total deadline, terminate its owning
  # task/connection on timeout, and return only :ok/:error. Retries MUST retain
  # the delivery's Message-ID; SMTP acceptance is not proof of inbox delivery or
  # exactly-once delivery across an uncertain external-side-effect/database commit.

  # @cc [owner:ghuntley,label:recovery] email-message-identity-config-independent
  # Message-ID MUST derive only from the immutable delivery ID and a fixed
  # application namespace. Changing sender configuration MUST NOT change the
  # identity of a retry; the current sender still supplies the From header.
  @spec send_bounded(String.t(), String.t(), String.t(), String.t()) :: :ok | :error
  defp send_bounded(email, token, delivery_id, locale) do
    task =
      Task.async(fn ->
        try do
          Marshall.Localization.put_locale(locale)
          # gen_smtp's receive timeout is much longer than its connect timeout.
          # This process owns the connection; the total deadline closes it too.
          Logger.metadata(marshall_mail: true)
          link = url(~p"/magic_link/#{token}")
          escaped = link |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

          message =
            new()
            |> from(Application.fetch_env!(:marshall, :mail_from))
            |> to(email)
            |> subject(gettext("Your Overalls sign-in link"))
            |> header("Message-ID", "<#{delivery_id}@#{@message_id_domain}>")
            |> text_body(
              gettext("Sign in to Overalls: %{link}\n\nIf you did not request this, ignore this email.", link: link)
            )
            |> html_body(
              "<div lang=\"#{locale}\" dir=\"#{Marshall.Localization.direction(locale)}\"><p>" <>
                Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(gettext("Sign in to Overalls:"))) <>
                "</p><p><a href=\"#{escaped}\">" <>
                Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(gettext("Sign in"))) <>
                "</a></p><p>" <>
                Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(gettext("If you did not request this, ignore this email."))) <>
                "</p></div>"
            )

          case Marshall.Mailer.deliver(message) do
            {:ok, _} -> :ok
            _ -> :error
          end
        rescue
          _ -> :error
        catch
          _, _ -> :error
        end
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] email-terminal-status-erases-payload
  # Marking a delivery delivered or expired MUST erase its encrypted payload in
  # that status update; retained delivery metadata MUST contain no usable link.
  defp finish(changeset, status) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> AshCloak.encrypt_and_set(:payload, nil)
  end

  defp failed(changeset) do
    Ash.Changeset.add_error(changeset, "Mail delivery failed")
  end

  @spec outcome({:ok, AuthEmail.t()} | {:error, term()}) :: :smtp_accepted | :expired | :failed
  defp outcome({:ok, %AuthEmail{status: :delivered}}), do: :smtp_accepted
  defp outcome({:ok, %AuthEmail{status: :expired}}), do: :expired
  defp outcome({:ok, _}), do: :failed
  defp outcome({:error, _}), do: :failed
end
