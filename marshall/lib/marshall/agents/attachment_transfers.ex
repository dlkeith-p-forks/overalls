defmodule Marshall.Agents.AttachmentTransfers do
  @moduledoc "Authorized durable chunk upload lifecycle."
  alias Marshall.Agents.{Attachment, AttachmentAudit, AttachmentChunks}
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{Authorization, Thread}
  require Marshall.Events
  require Ash.Query

  # @cc [owner:ghuntley,label:security;durability] attachment-buffer-upload
  # Buffered uploads MUST use encrypted durable chunks and publish atomically.
  # An identical retry MUST return the existing attachment without rewriting it;
  # any failed chunk or publication MUST roll back the entire buffered upload.
  @spec upload(String.t(), String.t(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def upload(actor, thread, key, bytes)
      when is_binary(bytes) and byte_size(bytes) <= 10_485_760 do
    if OverallsProtocol.uuid?(actor) and OverallsProtocol.uuid?(thread) do
      transaction(actor, fn ->
        sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        case begin_upload(actor, thread, key, byte_size(bytes), sha) do
          {:ok, %{state: :available} = metadata} ->
            {:ok, metadata}

          {:ok, %{id: id}} ->
            upload_parts!(actor, id, bytes, 0)

            case finish(actor, id) do
              {:ok, metadata} -> {:ok, metadata}
              {:error, reason} -> Ledger.rollback(reason)
            end

          {:error, reason} ->
            Ledger.rollback(reason)
        end
      end)
    else
      {:error, :invalid_upload}
    end
  end

  def upload(_, _, _, _), do: {:error, :invalid_upload}

  @spec upload_parts!(String.t(), String.t(), binary(), non_neg_integer()) :: :ok
  defp upload_parts!(_actor, _id, <<>>, _offset), do: :ok

  defp upload_parts!(actor, id, bytes, offset) do
    count = min(byte_size(bytes), 262_144)
    <<part::binary-size(^count), rest::binary>> = bytes

    case put(actor, id, offset, part) do
      {:ok, _} -> upload_parts!(actor, id, rest, offset + count)
      {:error, reason} -> Ledger.rollback(reason)
    end
  end

  # @cc [owner:ghuntley,label:security;durability] attachment-transfer-authority
  # Every mutation MUST recheck current thread write authority under the thread
  # lock. Begin retries MUST match declared content identity; publication MUST
  # verify complete durable bytes before the available transition commits.
  @spec begin_upload(String.t(), String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def begin_upload(actor, thread, key, size, sha)
      when is_binary(key) and byte_size(key) in 1..128 and is_integer(size) and
             size in 0..10_485_760 and is_binary(sha) do
    if OverallsProtocol.uuid?(actor) and OverallsProtocol.uuid?(thread) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) do
      transaction(actor, fn ->
        authorize!(actor, thread)

        row =
          case Ledger.read!(Attachment, thread_id: thread, idempotency_key: key) do
            [] ->
              Ledger.create!(Attachment, :create_pending, %{
                thread_id: thread,
                owner_id: actor,
                idempotency_key: key,
                size_bytes: size,
                sha256: sha
              })
              |> Ledger.update!(:begin_upload, %{})

            [%{size_bytes: ^size, sha256: ^sha, state: state} = row]
            when state in [:uploading, :available] ->
              row

            [%{size_bytes: ^size, sha256: ^sha, state: :failed} = row] ->
              Ledger.update!(row, :begin_upload, %{})

            _ ->
              Ledger.rollback(:idempotency_conflict)
          end

        audit!(actor, row, :begin_upload)
        {:ok, metadata(row)}
      end)
    else
      {:error, :invalid_upload}
    end
  end

  def begin_upload(_, _, _, _, _), do: {:error, :invalid_upload}

  @spec put(String.t(), String.t(), non_neg_integer(), binary()) ::
          {:ok, map()} | {:error, term()}
  def put(actor, id, offset, bytes) do
    with_attachment(actor, id, fn row ->
      case AttachmentChunks.put_locked(row, offset, bytes) do
        {:ok, _chunk_id} ->
          audit!(actor, row, :put_chunk)
          {:ok, %{id: row.id, offset: offset}}

        error ->
          error
      end
    end)
  end

  @spec finish(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def finish(actor, id) do
    with_attachment(actor, id, fn row ->
      case row do
        %{state: :available, storage_key: "chunks:" <> _} ->
          audit!(actor, row, :finish_upload)
          {:ok, metadata(row)}

        %{state: :uploading} ->
          with {:ok, _bytes} <- AttachmentChunks.assemble_locked(row) do
            published =
              Ledger.update!(row, :publish, %{
                storage_key: "chunks:" <> row.id,
                sha256: row.sha256,
                size_bytes: row.size_bytes,
                media_type: "application/octet-stream"
              })

            audit!(actor, published, :finish_upload)

            Ledger.after_commit(fn ->
              Marshall.Events.emit("attachment.operation",
                attachment_id: row.id,
                thread_id: row.thread_id,
                operation: :upload,
                outcome: :completed
              )
            end)

            {:ok, metadata(published)}
          end

        _ ->
          {:error, :attachment_unavailable}
      end
    end)
  end

  @spec delete(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def delete(actor, id) do
    with_attachment(
      actor,
      id,
      fn row ->
        if row.state in [:available, :quarantined, :failed] do
          deleting = Ledger.update!(row, :begin_delete, %{})
          audit!(actor, deleting, :delete)

          :ok = AttachmentChunks.delete_locked(deleting)
          deleted = Ledger.update!(deleting, :finish_delete, %{})
          audit!(actor, deleted, :delete)
          {:ok, %{id: deleted.id, state: deleted.state}}
        else
          {:error, :attachment_unavailable}
        end
      end,
      "manage"
    )
  end

  @spec expire_abandoned(DateTime.t()) :: non_neg_integer()
  def expire_abandoned(cutoff) do
    rows =
      Attachment
      |> Ash.Query.filter(state in [:pending, :uploading] and updated_at < ^cutoff)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

    Enum.reduce(rows, 0, fn row, count ->
      Ledger.transaction(fn ->
        locked = Ledger.lock!(Attachment, row.id)

        if locked && locked.state in [:pending, :uploading] &&
             DateTime.compare(locked.updated_at, cutoff) == :lt do
          failed = Ledger.update!(locked, :fail, %{failure_reason: "expired"})
          AttachmentChunks.delete_locked(failed)

          Ledger.create!(AttachmentAudit, :record, %{
            attachment_id: row.id,
            thread_id: row.thread_id,
            actor_id: nil,
            operation: :expire_upload,
            outcome: :completed
          })

          1
        else
          0
        end
      end)
      |> case do
        {:ok, n} -> count + n
        _ -> count
      end
    end)
  end

  # @cc [owner:ghuntley,label:security] attachment-transfer-read
  # Each chunk read MUST recheck current read authority and available state,
  # verify stored content integrity and return at most 256 KiB of content.
  @spec read(String.t(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def read(actor, id, offset) when is_integer(offset) and offset >= 0 do
    with_attachment(
      actor,
      id,
      fn row ->
        if row.state == :available and offset <= row.size_bytes and rem(offset, 262_144) == 0 do
          content =
            case row.storage_key do
              "chunks:" <> _ -> AttachmentChunks.assemble_locked(row)
              key -> Marshall.Agents.AttachmentStore.get(key)
            end

          with {:ok, bytes} <- content,
               true <-
                 byte_size(bytes) == row.size_bytes and
                   Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == row.sha256 do
            count = min(262_144, row.size_bytes - offset)
            audit!(actor, row, :read_chunk)

            {:ok,
             Map.merge(metadata(row), %{
               offset: offset,
               content_base64: Base.encode64(binary_part(bytes, offset, count))
             })}
          else
            _ -> {:error, :attachment_unavailable}
          end
        else
          {:error, :invalid_chunk}
        end
      end,
      "read"
    )
  end

  def read(_, _, _), do: {:error, :invalid_chunk}

  @spec with_attachment(String.t(), String.t(), (Attachment.t() -> term()), String.t()) :: term()
  defp with_attachment(actor, id, fun, permission \\ "write") do
    if OverallsProtocol.uuid?(actor) and OverallsProtocol.uuid?(id) do
      transaction(actor, fn ->
        row =
          case Ledger.read!(Attachment, id: id) do
            [row] -> row
            [] -> Ledger.rollback(:attachment_unavailable)
          end

        authorize!(actor, row.thread_id, permission)
        fun.(Ledger.lock!(Attachment, id) || Ledger.rollback(:attachment_unavailable))
      end)
    else
      {:error, :invalid_upload}
    end
  end

  @spec authorize!(String.t(), String.t(), String.t()) :: :ok
  defp authorize!(actor_id, id, permission \\ "write") do
    thread =
      if permission == "read",
        do: Ledger.lock_history!(Thread, id),
        else: Ledger.lock!(Thread, id)

    thread = thread || Ledger.rollback(:forbidden)
    actor = Marshall.Accounts.Security.current(actor_id)
    unless Authorization.allowed?(thread, actor, permission), do: Ledger.rollback(:forbidden)
    :ok
  end

  @spec transaction(String.t(), (-> term())) :: term()
  defp transaction(actor, fun) do
    case Ledger.transaction(fn -> %{result: fun.()} end, {:user, actor}) do
      {:ok, %{result: result}} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec audit!(String.t(), Attachment.t(), atom()) :: AttachmentAudit.t()
  defp audit!(actor, row, operation) do
    Ledger.create!(AttachmentAudit, :record, %{
      attachment_id: row.id,
      thread_id: row.thread_id,
      actor_id: actor,
      operation: operation,
      outcome: :completed
    })
  end

  @spec metadata(Attachment.t()) :: map()
  defp metadata(row),
    do: %{id: row.id, state: row.state, size_bytes: row.size_bytes, sha256: row.sha256}
end
