defmodule Marshall.Artifacts.Tickets do
  @moduledoc "Issues and redeems content-origin view tickets. Only hashes are stored."
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Audit, Authorization, Library, Version, ViewTicket}
  alias Marshall.Compute.Ledger

  @ttl_seconds 300

  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @spec issue(User.t(), Artifact.t(), Version.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def issue(%User{} = actor, %Artifact{} = artifact, %Version{} = version, content_host)
      when is_binary(content_host) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Ledger.transaction(
      fn ->
        locked = Ledger.lock!(Artifact, artifact.id) || Ledger.rollback(:not_found)
        if locked.state != :active, do: Ledger.rollback(:not_found)
        unless Authorization.allowed?(locked, actor, :read), do: Ledger.rollback(:not_found)

        Ledger.create!(ViewTicket, :issue, %{
          token_hash: hash(token),
          artifact_id: locked.id,
          version_number: version.number,
          user_id: actor.id,
          content_host: content_host,
          expires_at: DateTime.add(Ledger.now(), @ttl_seconds, :second)
        })

        Audit.record!(%{
          artifact_id: locked.id,
          actor_id: actor.id,
          kind: :ticket_issued,
          via: :web,
          version: version.number
        })

        token
      end,
      {:user, actor.id}
    )
  end

  # @cc [owner:ghuntley,label:security] artifact-ticket-redeem
  # Redeeming MUST find the ticket by hash only, require `issued`, unexpired,
  # the request's content host, an active artifact, the bound version, a
  # current owner account, a current active user and a fresh Cedar read. Every
  # failure answers the same closed refusal.
  @spec redeem(String.t(), String.t()) ::
          {:ok, %{artifact: Artifact.t(), version: Version.t(), user: User.t()}}
          | {:error, atom()}
  def redeem(token, host) when is_binary(token) and is_binary(host) do
    with true <- byte_size(token) in 40..64 || {:error, :invalid_ticket},
         [%ViewTicket{} = ticket] <- Ledger.read!(ViewTicket, token_hash: hash(token)),
         :issued <- ticket.state,
         :gt <- DateTime.compare(ticket.expires_at, Ledger.now()),
         true <- ticket.content_host == host,
         %User{deleted_at: nil, active: true} = user <-
           Marshall.Accounts.Security.current(ticket.user_id),
         [%Artifact{state: :active} = artifact] <- Ledger.read!(Artifact, id: ticket.artifact_id),
         true <- Authorization.allowed?(artifact, user, :read),
         {:ok, version} <- Library.version(artifact, ticket.version_number) do
      {:ok, %{artifact: artifact, version: version, user: user}}
    else
      _ -> {:error, :invalid_ticket}
    end
  end

  def redeem(_, _), do: {:error, :invalid_ticket}

  @spec hash(String.t()) :: binary()
  defp hash(token), do: :crypto.hash(:sha256, token)
end
