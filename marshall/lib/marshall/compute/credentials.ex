defmodule Marshall.Compute.Credentials do
  @moduledoc "Trusted operator enrollment and per-request authentication under the host lock."
  import Marshall.Compute.CredentialLifetime, only: [valid: 1]
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, HostCredential, Ledger}
  require Marshall.Events

  defmodule Issued do
    @moduledoc "One-time enrollment result. Never log or audit its token."
    @derive {Inspect, except: [:token]}
    @enforce_keys [:id, :host_id, :expires_at, :token]
    defstruct [:id, :host_id, :expires_at, :token]

    @type t :: %__MODULE__{
            id: String.t(),
            host_id: String.t(),
            expires_at: DateTime.t(),
            token: String.t()
          }
  end

  # @cc [owner:ghuntley,label:security] credentials-rotation-fences-authority
  # Rotation MUST archive prior credentials and invalidate the host's current
  # session/fresh report in the same host-locked transaction as issuing its new
  # bounded-lifetime credential. It MUST NOT release VM reservations.
  @doc "Issues or rotates a credential; TTL is explicit and capped at five 365-day years. Operator-only."
  @spec rotate(String.t(), pos_integer()) :: {:ok, Issued.t()} | {:error, term()}
  def rotate(host_id, ttl_seconds)
      when valid(ttl_seconds) do
    Ledger.transaction(
      fn ->
        host = Ledger.lock!(Host, host_id)
        unless host, do: Ledger.rollback(:unknown_host)
        if host.maintenance_mode == :retired, do: Ledger.rollback(:host_retired)
        archive_credentials(host_id)
        invalidate(host)
        secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        expires_at = DateTime.add(Ledger.now(), ttl_seconds, :second)

        credential =
          Ledger.create!(HostCredential, :issue, %{
            host_id: host_id,
            secret: secret,
            expires_at: expires_at
          })

        %Issued{
          id: credential.id,
          host_id: host_id,
          expires_at: expires_at,
          token: credential.id <> ":" <> secret
        }
      end,
      :operator
    )
    |> case do
      {:ok, issued} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.credentials_rotated",
            host_id: issued.host_id,
            credential_id: issued.id
          )
        end

        {:ok, issued}

      other ->
        other
    end
  end

  def rotate(_, _), do: {:error, :invalid_lifetime}

  @doc "Revokes all current credentials and invalidates observations, retaining VM reservations."
  @spec revoke(String.t()) :: {:ok, :ok} | {:error, term()}
  def revoke(host_id) do
    Ledger.transaction(
      fn ->
        host = Ledger.lock!(Host, host_id)
        unless host, do: Ledger.rollback(:unknown_host)
        archive_credentials(host_id)
        invalidate(host)
        :ok
      end,
      :operator
    )
    |> case do
      {:ok, :ok} = ok ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.credentials_revoked", host_id: host_id)
        end

        ok

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:security] credentials-revalidate-under-lock
  # with_host MUST reread the current unarchived credential after locking its
  # non-retired host, check database-clock expiry and compare the decrypted secret
  # securely before invoking the callback. Decryption failure MUST return
  # temporarily_unavailable rather than imply that the credential is inactive.
  @doc "Authenticates and invokes a trusted coordinator callback while holding the host row lock."
  @spec with_host(String.t(), (Host.t() -> term())) :: {:ok, term()} | {:error, term()}
  def with_host(token, fun) do
    with {:ok, id, secret} <- parse(token) do
      Ledger.transaction(fn ->
        credential = current!(id)
        host = Ledger.lock!(Host, credential.host_id)
        unless host, do: Ledger.rollback(:unauthorized)
        if host.maintenance_mode == :retired, do: Ledger.rollback(:unauthorized)
        # Rotation/revocation take the same lock. Never trust the pre-lock lookup.
        credential = current!(id)

        if DateTime.compare(credential.expires_at, Ledger.now()) != :gt,
          do: Ledger.rollback(:unauthorized)

        secret_value =
          case decrypt(credential) do
            {:ok, value} -> value
            :error -> Ledger.rollback(:temporarily_unavailable)
          end

        unless is_binary(secret_value) and
                 Plug.Crypto.secure_compare(secret_value, secret),
               do: Ledger.rollback(:unauthorized)

        fun.(host)
      end)
    end
    |> case do
      {:error, :unauthorized} = error ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.auth_rejected", reason: :unauthorized)
        end

        error

      other ->
        other
    end
  end

  @spec parse(term()) :: {:ok, String.t(), String.t()} | {:error, :unauthorized}
  defp parse(token) when is_binary(token) and byte_size(token) == 80 do
    with [id, secret] <- String.split(token, ":", parts: 2),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, secret) do
      {:ok, id, secret}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp parse(_), do: {:error, :unauthorized}

  defp current!(id) do
    case Ledger.read!(HostCredential, id: id) do
      [credential] -> credential
      _ -> Ledger.rollback(:unauthorized)
    end
  end

  defp decrypt(credential) do
    {:ok, Ash.load!(credential, :secret, actor: SystemActor.compute()).secret}
  rescue
    # Cloak's exception diagnostics can contain ciphertext. Fail closed without
    # returning or logging those diagnostics at the remote credential boundary.
    _ -> :error
  end

  defp archive_credentials(host_id) do
    Enum.each(Ledger.read!(HostCredential, host_id: host_id), fn credential ->
      Ledger.archive!(credential, :revoke)
    end)
  end

  defp invalidate(host) do
    Ledger.update!(host, :disconnect, %{
      connection_epoch: host.connection_epoch + 1,
      connection_session_id: nil,
      reported_at: nil
    })
  end
end
