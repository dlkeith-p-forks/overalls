defmodule Marshall.Agents.AttachmentTool do
  @moduledoc "Typed, bounded attachment operations for agent commands."
  # @cc [owner:ghuntley,label:security;durability] attachment-bytes-outside-context
  # Uploads MUST persist bytes in the attachment store and return only bounded metadata and an opaque id.
  # Downloads MUST require the owner/thread scope and MUST never return bytes to diagnostics.
  import Ecto.Query
  alias Marshall.Agents.Attachment
  alias Marshall.Agents.AttachmentStore
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.Threads.{Authorization, Thread}
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] attachment-input-identifiers
  # Malformed actor, thread and attachment identifiers MUST return closed errors
  # before resource queries, rather than raising and leaving commands queued.
  @max_bytes 10 * 1024 * 1024

  @spec upload(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def upload(owner_id, thread_id, %{"idempotency_key" => key, "content_base64" => content} = args)
      when is_binary(owner_id) and is_binary(thread_id) and is_binary(key) and is_binary(content) do
    with {:ok, bytes} <- Base.decode64(content) do
      upload_bytes(owner_id, thread_id, key, bytes, args)
    else
      :error -> {:error, :invalid_base64}
    end
  end

  def upload(_, _, _), do: {:error, :invalid_upload}

  @doc "Persist bytes received by an authenticated transfer, outside model arguments."
  @spec upload_bytes(String.t(), String.t(), String.t(), binary(), map()) ::
          {:ok, map()} | {:error, atom()}
  def upload_bytes(owner_id, thread_id, key, bytes, args)
      when is_binary(owner_id) and is_binary(thread_id) and is_binary(key) and
             byte_size(key) in 1..128 and is_binary(bytes) and is_map(args) do
    cond do
      not OverallsProtocol.uuid?(owner_id) or not OverallsProtocol.uuid?(thread_id) ->
        {:error, :invalid_upload}

      byte_size(bytes) > @max_bytes ->
        {:error, :attachment_too_large}

      true ->
        case Ledger.transaction(
               fn ->
                 Ledger.lock!(Thread, thread_id) || Ledger.rollback(:forbidden)

                 result =
                   with :ok <- authorize(owner_id, thread_id, "write"),
                        {:ok, existing} <- existing(thread_id, key) do
                     create_or_return(existing, owner_id, thread_id, key, bytes, args)
                   end

                 %{result: result}
               end,
               {:user, owner_id}
             ) do
          {:ok, %{result: result}} -> result
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def upload_bytes(_, _, _, _, _), do: {:error, :invalid_upload}

  @spec download(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def download(owner_id, attachment_id) when is_binary(owner_id) and is_binary(attachment_id) do
    if not OverallsProtocol.uuid?(owner_id) or not OverallsProtocol.uuid?(attachment_id) do
      {:error, :attachment_unavailable}
    else
      case Ledger.transaction(
             fn ->
               result =
                 if OverallsProtocol.uuid?(owner_id) and OverallsProtocol.uuid?(attachment_id),
                   do: issue_download_locked(owner_id, attachment_id),
                   else: {:error, :attachment_unavailable}

               %{result: result}
             end,
             {:user, owner_id}
           ) do
        {:ok, %{result: result}} -> result
        {:error, _} -> {:error, :attachment_unavailable}
      end
    end
  end

  def download(_, _), do: {:error, :attachment_unavailable}

  # @cc [owner:ghuntley,label:security;observability] attachment-token-issuance
  # Issuance MUST serialize with thread grant changes and refuse unavailable
  # attachments. Outcome diagnostics MUST wait for the outer transaction commit.
  @spec issue_download_locked(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  defp issue_download_locked(owner_id, attachment_id) do
    case Ledger.read!(Attachment, id: attachment_id) do
      [%{state: :available} = row] ->
        with %Thread{} <- Ledger.lock_history!(Thread, row.thread_id),
             :ok <- authorize(owner_id, row.thread_id, "read"),
             %{state: :available} = row <- Ledger.lock!(Attachment, attachment_id) do
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

          expires_at =
            DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:microsecond)

          Repo.update_all(from(a in "agent_attachments", where: a.id == type(^row.id, Ecto.UUID)),
            set: [
              download_token_hash: hash(owner_id <> ":" <> token),
              download_token_expires_at: expires_at
            ]
          )

          Ledger.create!(Marshall.Agents.AttachmentAudit, :record, %{
            attachment_id: row.id,
            thread_id: row.thread_id,
            actor_id: owner_id,
            operation: :issue_token,
            outcome: :completed
          })

          Ledger.after_commit(fn ->
            Marshall.Events.emit("attachment.operation",
              attachment_id: row.id,
              thread_id: row.thread_id,
              operation: :download,
              outcome: :completed
            )
          end)

          {:ok,
           %{
             id: row.id,
             thread_id: row.thread_id,
             media_type: row.media_type,
             size_bytes: row.size_bytes,
             download_token: token,
             expires_at: expires_at
           }}
        else
          {:error, :forbidden} -> {:error, :forbidden}
          _ -> {:error, :attachment_unavailable}
        end

      _ ->
        {:error, :attachment_unavailable}
    end
  end

  @spec resolve_download(String.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def resolve_download(owner_id, attachment_id, token)
      when is_binary(owner_id) and is_binary(attachment_id) and is_binary(token) do
    if not OverallsProtocol.uuid?(owner_id) or not OverallsProtocol.uuid?(attachment_id) do
      {:error, :invalid_download_token}
    else
      case Ledger.transaction(
             fn ->
               result =
                 if OverallsProtocol.uuid?(owner_id) and OverallsProtocol.uuid?(attachment_id),
                   do: resolve_download_locked(owner_id, attachment_id, token),
                   else: {:error, :invalid_download_token}

               %{result: result}
             end,
             {:user, owner_id}
           ) do
        {:ok, %{result: result}} -> result
        {:error, _} -> {:error, :invalid_download_token}
      end
    end
  end

  def resolve_download(_, _, _), do: {:error, :invalid_download_token}

  # @cc [owner:ghuntley,label:recovery;security] attachment-download-consumption
  # Storage read failures MUST leave the token usable until expiry. Bytes MUST
  # only be returned after current authorization, matching the persisted digest
  # and size, and atomic token consumption. Integrity failures MUST NOT consume tokens.
  @spec resolve_download_locked(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, atom()}
  defp resolve_download_locked(owner_id, attachment_id, token) do
    now = DateTime.utc_now()

    case Ledger.read!(Attachment, id: attachment_id, state: :available) do
      [
        %{
          storage_key: _key,
          download_token_hash: token_hash,
          download_token_expires_at: expires_at
        } =
            row
      ]
      when is_binary(token_hash) and not is_nil(expires_at) ->
        with true <- DateTime.compare(now, expires_at) == :lt,
             true <- Plug.Crypto.secure_compare(token_hash, hash(owner_id <> ":" <> token)),
             %Thread{} <- Ledger.lock_history!(Thread, row.thread_id),
             :ok <- authorize(owner_id, row.thread_id, "read"),
             %{state: :available, download_token_hash: ^token_hash} = row <-
               Ledger.lock!(Attachment, attachment_id),
             {:ok, bytes} <- read_content(row),
             true <- byte_size(bytes) == row.size_bytes and hash(bytes) == row.sha256,
             {1, _} <-
               Repo.update_all(
                 from(a in "agent_attachments",
                   where:
                     a.id == type(^row.id, Ecto.UUID) and a.state == "available" and
                       a.download_token_hash == ^token_hash and
                       a.download_token_expires_at > fragment("clock_timestamp()")
                 ),
                 set: [download_token_hash: nil, download_token_expires_at: nil]
               ) do
          Ledger.create!(Marshall.Agents.AttachmentAudit, :record, %{
            attachment_id: row.id,
            thread_id: row.thread_id,
            actor_id: owner_id,
            operation: :redeem_token,
            outcome: :completed
          })

          {:ok, bytes}
        else
          _ -> {:error, :invalid_download_token}
        end

      _ ->
        {:error, :invalid_download_token}
    end
  end

  @spec read_content(Attachment.t()) :: {:ok, binary()} | {:error, atom()}
  defp read_content(%{storage_key: "chunks:" <> _} = row),
    do: Marshall.Agents.AttachmentChunks.assemble_locked(row)

  defp read_content(%{storage_key: key}), do: AttachmentStore.get(key)

  # @cc [owner:ghuntley,label:durability] attachment-thread-idempotency
  # Authorized writers MUST share the thread-scoped idempotency namespace.
  # Replays MUST preserve the original attachment identity and uploader.
  @spec existing(String.t(), String.t()) :: {:ok, Attachment.t() | nil}
  defp existing(thread_id, key) do
    case Ledger.read!(Attachment, thread_id: thread_id, idempotency_key: key) do
      [] -> {:ok, nil}
      [row] -> {:ok, row}
    end
  end

  defp create_or_return(
         %{id: id, state: :available} = row,
         _owner,
         _thread,
         _key,
         bytes,
         _args
       ) do
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if row.sha256 == sha and row.size_bytes == byte_size(bytes),
      do:
        {:ok,
         %{
           id: id,
           state: "available",
           sha256: row.sha256,
           size_bytes: row.size_bytes,
           media_type: row.media_type
         }},
      else: {:error, :idempotency_conflict}
  end

  defp create_or_return(nil, owner_id, thread_id, key, bytes, args) do
    row =
      Ledger.create!(Attachment, :create_pending, %{
        thread_id: thread_id,
        owner_id: owner_id,
        idempotency_key: key,
        sha256: hash(bytes),
        size_bytes: byte_size(bytes),
        display_name: Map.get(args, "display_name")
      })

    persist_upload(row, bytes, args)
  end

  defp create_or_return(%{state: :failed} = row, _owner, _thread, _key, bytes, args) do
    if row.sha256 == hash(bytes) and row.size_bytes == byte_size(bytes),
      do: persist_upload(row, bytes, args),
      else: {:error, :idempotency_conflict}
  end

  defp create_or_return(_, _, _, _, _, _), do: {:error, :attachment_unavailable}

  @spec persist_upload(Attachment.t(), binary(), map()) :: {:ok, map()} | {:error, atom()}
  defp persist_upload(row, bytes, args) do
    row = Ledger.update!(row, :begin_upload, %{})
    storage_key = "threads/" <> row.thread_id <> "/" <> row.id
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    media_type = Map.get(args, "media_type", "application/octet-stream")

    case AttachmentStore.put(storage_key, bytes) do
      :ok ->
        row =
          Ledger.update!(row, :publish, %{
            storage_key: storage_key,
            sha256: sha,
            size_bytes: byte_size(bytes),
            media_type: media_type
          })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("attachment.operation",
            attachment_id: row.id,
            thread_id: row.thread_id,
            operation: :upload,
            outcome: :completed
          )
        end)

        {:ok,
         %{
           id: row.id,
           state: "available",
           sha256: sha,
           size_bytes: byte_size(bytes),
           media_type: media_type
         }}

      {:error, _} ->
        Ledger.update!(row, :fail, %{failure_reason: "storage_unavailable"})

        Ledger.after_commit(fn ->
          Marshall.Events.emit("attachment.operation",
            attachment_id: row.id,
            thread_id: row.thread_id,
            operation: :upload,
            outcome: :failed
          )
        end)

        {:error, :attachment_persist_failed}
    end
  end

  defp authorize(owner_id, thread_id, action) do
    rows =
      if action == "read",
        do: Ledger.history!(Thread, id: thread_id),
        else: Ledger.read!(Thread, id: thread_id)

    with [%Thread{} = thread] <- rows,
         %Marshall.Accounts.User{} = actor <- Marshall.Accounts.Security.current(owner_id),
         true <- Authorization.allowed?(thread, actor, action) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
