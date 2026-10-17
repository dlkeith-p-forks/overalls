defmodule Marshall.Terminal.Tickets do
  @moduledoc "Single-use terminal attach tickets bound to one registry session and mode."

  import Ash.Expr
  require Ash.Query

  alias Marshall.Terminal.Ticket

  @ttl_seconds 30

  # @cc [owner:ghuntley,label:security] tickets-single-use-and-bound
  # issue/3 MUST mint a random 256-bit ticket bound to one session, actor and
  # mode with a short fixed expiry; only its SHA-256 digest may be persisted.
  # consume/1 MUST atomically remove it so a replay cannot open another
  # attachment on this or any connected Marshall replica.
  @spec issue(String.t(), String.t(), :rw | :ro) :: {:ok, String.t()} | {:error, term()}
  def issue(session_id, actor_id, mode) when mode in [:rw, :ro] do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    attributes = %{
      token_hash: digest(token),
      session_id: session_id,
      actor_id: actor_id,
      mode: mode,
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
    }

    case Marshall.Terminal.create_ticket(attributes, authorize?: false) do
      {:ok, _ticket} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec consume(String.t()) ::
          {:ok, %{session_id: String.t(), actor_id: String.t(), mode: :rw | :ro}}
          | {:error, :invalid_ticket}
  def consume(token) when is_binary(token) and byte_size(token) in 20..64 do
    result =
      Marshall.Repo.transaction(fn ->
        query =
          Ticket
          |> Ash.Query.filter(expr(token_hash == ^digest(token)))
          |> Ash.Query.lock("FOR UPDATE")

        with {:ok, %Ticket{} = ticket} <- Ash.read_one(query, authorize?: false),
             :gt <- DateTime.compare(ticket.expires_at, DateTime.utc_now()),
             :ok <- Ash.destroy(ticket, authorize?: false) do
          %{session_id: ticket.session_id, actor_id: ticket.actor_id, mode: ticket.mode}
        else
          _ -> Marshall.Repo.rollback(:invalid_ticket)
        end
      end)

    case result do
      {:ok, claim} -> {:ok, claim}
      {:error, _reason} -> {:error, :invalid_ticket}
    end
  end

  def consume(_), do: {:error, :invalid_ticket}

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
