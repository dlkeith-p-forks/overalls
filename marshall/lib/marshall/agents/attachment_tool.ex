defmodule Marshall.Agents.AttachmentTool do
  @moduledoc "Typed, bounded attachment operations for agent commands."
  # @cc [owner:ghuntley,label:security;durability] attachment-bytes-outside-context
  # Uploads MUST persist bytes in the attachment store and return only bounded metadata and an opaque id.
  # Downloads MUST require the owner/thread scope and MUST never return bytes to diagnostics.
  import Ecto.Query
  alias Marshall.Agents.AttachmentState
  alias Marshall.Agents.AttachmentStore
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.Threads.{Authorization, Thread}
  require Marshall.Events

  @max_bytes 10 * 1024 * 1024

  @spec upload(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def upload(owner_id, thread_id, %{"idempotency_key" => key, "content_base64" => content} = args)
      when is_binary(owner_id) and is_binary(thread_id) and is_binary(key) and is_binary(content) do
    with {:ok, bytes} <- Base.decode64(content),
         true <- byte_size(bytes) <= @max_bytes,
         :ok <- authorize(owner_id, thread_id, "write"),
         {:ok, existing} <- existing(owner_id, thread_id, key),
         {:ok, result} <- create_or_return(existing, owner_id, thread_id, key, bytes, args) do
      {:ok, result}
    else
      false -> {:error, :attachment_too_large}
      :error -> {:error, :invalid_base64}
      {:error, reason} -> {:error, reason}
    end
  end

  def upload(_, _, _), do: {:error, :invalid_upload}

  @spec download(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def download(owner_id, attachment_id) when is_binary(owner_id) and is_binary(attachment_id) do
    case Repo.one(
           from(a in "agent_attachments",
             where: a.id == ^attachment_id and a.owner_id == ^owner_id,
             select: a
           )
         ) do
      %{state: "available"} = row ->
        with :ok <- authorize(owner_id, row.thread_id, "read") do
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

          expires_at =
            DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:microsecond)

          Repo.update_all(from(a in "agent_attachments", where: a.id == ^row.id),
            set: [download_token_hash: hash(token), download_token_expires_at: expires_at]
          )

          Marshall.Events.emit("attachment.operation",
            attachment_id: row.id,
            thread_id: row.thread_id,
            operation: :download,
            outcome: :completed
          )

          {:ok,
           %{
             id: row.id,
             thread_id: row.thread_id,
             media_type: row.media_type,
             size_bytes: row.size_bytes,
             download_token: token,
             expires_at: expires_at
           }}
        end

      _ ->
        {:error, :attachment_unavailable}
    end
  end

  def download(_, _), do: {:error, :attachment_unavailable}

  @spec resolve_download(String.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def resolve_download(owner_id, attachment_id, token)
      when is_binary(owner_id) and is_binary(attachment_id) and is_binary(token) do
    now = DateTime.utc_now()

    case Repo.one(
           from(a in "agent_attachments",
             where: a.id == ^attachment_id and a.owner_id == ^owner_id and a.state == "available",
             select: a
           )
         ) do
      %{storage_key: key, download_token_hash: token_hash, download_token_expires_at: expires_at} =
          row
      when is_binary(token_hash) and not is_nil(expires_at) ->
        if DateTime.compare(now, expires_at) == :lt and
             Plug.Crypto.secure_compare(token_hash, hash(token)) do
          Repo.update_all(from(a in "agent_attachments", where: a.id == ^row.id),
            set: [download_token_hash: nil, download_token_expires_at: nil]
          )

          AttachmentStore.get(key)
        else
          {:error, :invalid_download_token}
        end

      _ ->
        {:error, :invalid_download_token}
    end
  end

  def resolve_download(_, _, _), do: {:error, :invalid_download_token}

  defp existing(owner_id, thread_id, key) do
    {:ok,
     Repo.one(
       from(a in "agent_attachments",
         where:
           a.owner_id == ^owner_id and a.thread_id == ^thread_id and a.idempotency_key == ^key,
         select: a
       )
     )}
  end

  defp create_or_return(
         %{id: id, state: "available"} = row,
         _owner,
         _thread,
         _key,
         _bytes,
         _args
       ),
       do: {:ok, %{id: id, state: row.state}}

  defp create_or_return(nil, owner_id, thread_id, key, bytes, args) do
    id = Ecto.UUID.generate()
    storage_key = "threads/" <> thread_id <> "/" <> id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    media_type = Map.get(args, "media_type", "application/octet-stream")
    display_name = Map.get(args, "display_name")

    with :ok <- AttachmentState.transition(:pending, :uploading),
         {:ok, _} <-
           Repo.insert_all("agent_attachments", [
             %{
               id: id,
               thread_id: thread_id,
               owner_id: owner_id,
               state: "uploading",
               display_name: display_name,
               idempotency_key: key,
               inserted_at: now,
               updated_at: now
             }
           ]),
         :ok <- AttachmentStore.put(storage_key, bytes),
         :ok <- AttachmentState.transition(:uploading, :available),
         {1, _} <-
           Repo.update_all(
             from(a in "agent_attachments", where: a.id == ^id),
             set: [
               state: "available",
               storage_key: storage_key,
               sha256: sha,
               size_bytes: byte_size(bytes),
               media_type: media_type,
               updated_at: now
             ]
           ) do
      Marshall.Events.emit("attachment.operation",
        attachment_id: id,
        thread_id: thread_id,
        operation: :upload,
        outcome: :completed
      )

      {:ok,
       %{
         id: id,
         state: "available",
         sha256: sha,
         size_bytes: byte_size(bytes),
         media_type: media_type
       }}
    else
      _ -> {:error, :attachment_persist_failed}
    end
  end

  defp create_or_return(_, _, _, _, _, _), do: {:error, :attachment_unavailable}

  defp authorize(owner_id, thread_id, action) do
    with [%Thread{} = thread] <- Ledger.read!(Thread, id: thread_id),
         %Marshall.Accounts.User{} = actor <- Marshall.Accounts.Security.current(owner_id),
         true <- Authorization.allowed?(thread, actor, action) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end