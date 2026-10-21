defmodule Marshall.Agents.AttachmentToolTest do
  use Marshall.DataCase, async: false
  alias Marshall.Agents.AttachmentTool

  test "upload persists available metadata through resource transitions" do
    actor = Marshall.ComputeFixtures.user()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Attachment integration test",
          mode: :medium,
          machine_spec: %{
            architecture: :x86_64,
            profile: :standard,
            image_id: "sha256:" <> String.duplicate("a", 64),
            vcpu: 2,
            memory_bytes: 4_294_967_296,
            disk_bytes: 42_949_672_960,
            team_id: nil
          },
          idempotency_key: Ecto.UUID.generate()
        },
        actor: actor
      )

    chunk_bytes = String.duplicate("x", 262_144) <> "tail"

    assert {:ok, :ok} =
             Marshall.Compute.Ledger.transaction(fn ->
               pending =
                 Marshall.Compute.Ledger.create!(Marshall.Agents.Attachment, :create_pending, %{
                   thread_id: thread.id,
                   owner_id: actor.id,
                   idempotency_key: "chunks",
                   size_bytes: byte_size(chunk_bytes),
                   sha256: Base.encode16(:crypto.hash(:sha256, chunk_bytes), case: :lower)
                 })

               uploading = Marshall.Compute.Ledger.update!(pending, :begin_upload, %{})
               chunks = Marshall.Agents.AttachmentChunks
               assert {:ok, tail_id} = chunks.put_locked(uploading, 262_144, "tail")
               assert {:error, :incomplete_upload} = chunks.assemble_locked(uploading)
               assert {:ok, ^tail_id} = chunks.put_locked(uploading, 262_144, "tail")
               assert {:error, :chunk_conflict} = chunks.put_locked(uploading, 262_144, "fail")
               assert {:error, :invalid_chunk} = chunks.put_locked(uploading, 1, "tail")
               assert {:ok, _} = chunks.put_locked(uploading, 0, String.duplicate("x", 262_144))
               assert {:ok, ^chunk_bytes} = chunks.assemble_locked(uploading)

               %{rows: [[encrypted]]} =
                 Ecto.Adapters.SQL.query!(
                   Marshall.Repo,
                   "SELECT encrypted_bytes FROM agent_attachment_chunks WHERE id = $1",
                   [Ecto.UUID.dump!(tail_id)],
                   log: false
                 )

               assert encrypted != "tail"
               :ok
             end)

    transfers = Marshall.Agents.AttachmentTransfers
    digest = Base.encode16(:crypto.hash(:sha256, "durable"), case: :lower)

    assert {:ok, %{id: transfer_id, state: :uploading}} =
             transfers.begin_upload(actor.id, thread.id, "durable", 7, digest)

    assert {:ok, %{id: ^transfer_id}} =
             transfers.begin_upload(actor.id, thread.id, "durable", 7, digest)

    assert {:error, :idempotency_conflict} =
             transfers.begin_upload(actor.id, thread.id, "durable", 8, digest)

    assert {:error, :incomplete_upload} = transfers.finish(actor.id, transfer_id)
    outsider = Marshall.ComputeFixtures.user()
    assert {:error, :forbidden} = transfers.put(outsider.id, transfer_id, 0, "durable")
    assert {:ok, _} = transfers.put(actor.id, transfer_id, 0, "durable")
    assert {:ok, %{state: :available}} = transfers.finish(actor.id, transfer_id)
    assert {:ok, %{state: :available}} = transfers.finish(actor.id, transfer_id)
    assert {:error, :invalid_chunk} = transfers.put(actor.id, transfer_id, 0, "durable")

    assert {:ok, %{content_base64: encoded}} = transfers.read(actor.id, transfer_id, 0)
    assert Base.decode64!(encoded) == "durable"

    receipts =
      Marshall.Compute.Ledger.read!(Marshall.Agents.AttachmentAudit,
        attachment_id: transfer_id
      )

    assert Enum.frequencies_by(receipts, & &1.operation) == %{
             begin_upload: 2,
             put_chunk: 1,
             finish_upload: 2,
             read_chunk: 1
           }

    assert Enum.all?(receipts, fn receipt ->
             receipt.actor_id == actor.id and receipt.thread_id == thread.id and
               receipt.outcome == :completed
           end)

    assert {:ok, %{download_token: durable_token}} =
             AttachmentTool.download(actor.id, transfer_id)

    assert {:ok, "durable"} =
             AttachmentTool.resolve_download(actor.id, transfer_id, durable_token)

    empty_digest = Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

    assert {:ok, %{id: empty_id}} =
             transfers.begin_upload(actor.id, thread.id, "empty", 0, empty_digest)

    assert {:ok, %{state: :available}} = transfers.finish(actor.id, empty_id)

    store = Marshall.Agents.AttachmentStore
    previous = Application.get_env(:marshall, store)
    root = Path.join(System.tmp_dir!(), "attachment-integration-#{Ecto.UUID.generate()}")

    Application.put_env(:marshall, store,
      root: root,
      encryption_key: :crypto.strong_rand_bytes(32)
    )

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:marshall, store),
        else: Application.put_env(:marshall, store, previous)

      File.rm_rf!(root)
    end)

    assert {:ok, %{id: id, state: "available"}} =
             AttachmentTool.upload(actor.id, thread.id, %{
               "idempotency_key" => "first",
               "content_base64" => Base.encode64("private bytes")
             })

    [row] = Marshall.Compute.Ledger.read!(Marshall.Agents.Attachment, id: id)
    assert row.state == :available
    assert row.thread_id == thread.id
    assert {:ok, "private bytes"} = store.get(row.storage_key)

    assert {:ok, %{id: ^id, state: "available"}} =
             AttachmentTool.upload(actor.id, thread.id, %{
               "idempotency_key" => "first",
               "content_base64" => Base.encode64("private bytes")
             })

    assert {:error, :idempotency_conflict} =
             AttachmentTool.upload(actor.id, thread.id, %{
               "idempotency_key" => "first",
               "content_base64" => Base.encode64("different bytes")
             })

    assert {:ok, "private bytes"} = store.get(row.storage_key)
    assert {:ok, %{download_token: prior_token}} = AttachmentTool.download(actor.id, id)

    assert {:error, :test_rollback} =
             Marshall.Compute.Ledger.transaction(fn ->
               assert {:ok, %{download_token: replacement}} =
                        AttachmentTool.download(actor.id, id)

               assert replacement != prior_token
               Marshall.Compute.Ledger.rollback(:test_rollback)
             end)

    assert {:ok, "private bytes"} = AttachmentTool.resolve_download(actor.id, id, prior_token)

    assert {:ok, %{download_token: token}} = AttachmentTool.download(actor.id, id)

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor.id, id, "wrong-token")

    configured_store = Application.get_env(:marshall, store)
    Application.put_env(:marshall, store, root: root)

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor.id, id, token)

    Application.put_env(:marshall, store, configured_store)

    # A valid encrypted envelope for different bytes must not satisfy this ID.
    assert :ok = store.put(row.storage_key, "swapped bytes")

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor.id, id, token)

    assert :ok = store.put(row.storage_key, "private bytes")

    assert {:ok, "private bytes"} = AttachmentTool.resolve_download(actor.id, id, token)

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor.id, id, token)

    assert {:ok, %{download_token: racing_token}} = AttachmentTool.download(actor.id, id)

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          AttachmentTool.resolve_download(actor.id, id, racing_token)
        end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, "private bytes"})) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_download_token})) == 7

    reader = Marshall.ComputeFixtures.user()
    configured = Application.get_env(:marshall, store)
    Application.put_env(:marshall, store, root: root)

    assert {:error, :attachment_persist_failed} =
             AttachmentTool.upload_bytes(actor.id, thread.id, "recover", "retry bytes", %{})

    [failed] =
      Marshall.Compute.Ledger.read!(Marshall.Agents.Attachment,
        thread_id: thread.id,
        idempotency_key: "recover"
      )

    assert failed.state == :failed
    assert {:error, :attachment_unavailable} = AttachmentTool.download(actor.id, failed.id)
    Application.put_env(:marshall, store, configured)

    assert {:error, :idempotency_conflict} =
             AttachmentTool.upload_bytes(actor.id, thread.id, "recover", "changed", %{})

    assert {:ok, %{id: recovered}} =
             AttachmentTool.upload_bytes(actor.id, thread.id, "recover", "retry bytes", %{})

    assert recovered == failed.id
    assert {:error, :forbidden} = AttachmentTool.download(reader.id, id)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(reader.email),
                 role: :viewer,
                 idempotency_key: Ecto.UUID.generate()
               },
               actor: actor
             )

    assert {:ok, %{download_token: shared_token}} = AttachmentTool.download(reader.id, id)

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor.id, id, shared_token)

    assert {:ok, "private bytes"} = AttachmentTool.resolve_download(reader.id, id, shared_token)

    assert {:error, :forbidden} =
             AttachmentTool.upload_bytes(reader.id, thread.id, "reader", "bytes", %{})

    assert {:ok, %{download_token: revoked_token}} = AttachmentTool.download(reader.id, id)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(reader.email),
                 role: :revoked,
                 idempotency_key: Ecto.UUID.generate()
               },
               actor: actor
             )

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(reader.id, id, revoked_token)

    assert {:error, :forbidden} = AttachmentTool.download(reader.id, id)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(reader.email),
                 role: :operator,
                 idempotency_key: Ecto.UUID.generate()
               },
               actor: actor
             )

    assert {:ok, %{id: ^id}} =
             AttachmentTool.upload_bytes(reader.id, thread.id, "first", "private bytes", %{})

    assert {:error, :idempotency_conflict} =
             AttachmentTool.upload_bytes(reader.id, thread.id, "first", "changed", %{})

    [replayed] =
      Marshall.Compute.Ledger.read!(Marshall.Agents.Attachment,
        thread_id: thread.id,
        idempotency_key: "first"
      )

    assert replayed.owner_id == actor.id
    assert replayed.id == id
  end

  test "malformed identifiers refuse without resource casting exceptions" do
    valid = Ecto.UUID.generate()

    for invalid <- ["", "bad-id", String.duplicate("a", 36)] do
      assert {:error, :invalid_upload} =
               AttachmentTool.upload_bytes(valid, invalid, "key", "", %{})

      assert {:error, :invalid_upload} =
               AttachmentTool.upload_bytes(invalid, valid, "key", "", %{})

      assert {:error, :attachment_unavailable} = AttachmentTool.download(valid, invalid)
      assert {:error, :attachment_unavailable} = AttachmentTool.download(invalid, valid)

      assert {:error, :invalid_download_token} =
               AttachmentTool.resolve_download(valid, invalid, "token")

      assert {:error, :invalid_download_token} =
               AttachmentTool.resolve_download(invalid, valid, "token")
    end
  end

  test "unknown attachments refuse download and redemption without raising" do
    actor_id = Ecto.UUID.generate()
    attachment_id = Ecto.UUID.generate()
    assert {:error, :attachment_unavailable} = AttachmentTool.download(actor_id, attachment_id)

    assert {:error, :invalid_download_token} =
             AttachmentTool.resolve_download(actor_id, attachment_id, "unknown-token")
  end

  test "explicit deletion requires manage authority and removes durable chunks" do
    actor = Marshall.ComputeFixtures.user()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "delete",
          mode: :medium,
          machine_spec: %{
            architecture: :x86_64,
            profile: :standard,
            image_id: "sha256:" <> String.duplicate("a", 64),
            vcpu: 2,
            memory_bytes: 4_294_967_296,
            disk_bytes: 42_949_672_960,
            team_id: nil
          },
          idempotency_key: Ash.UUID.generate()
        },
        actor: actor
      )

    assert {:ok, %{id: id}} =
             Marshall.Agents.AttachmentTransfers.upload(
               actor.id,
               thread.id,
               "delete",
               "delete me"
             )

    assert {:ok, %{state: :deleted}} = Marshall.Agents.AttachmentTransfers.delete(actor.id, id)

    assert Marshall.Agents.AttachmentTransfers.read(actor.id, id, 0) in [
             {:error, :attachment_unavailable},
             {:error, :invalid_chunk}
           ]

    assert Enum.any?(
             Marshall.Compute.Ledger.read!(Marshall.Agents.AttachmentAudit, attachment_id: id),
             &(&1.operation == :delete and &1.outcome == :completed)
           )
  end

  test "abandoned uploads expire with a system audit and can be retried" do
    actor = Marshall.ComputeFixtures.user()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "expire",
          mode: :medium,
          machine_spec: %{
            architecture: :x86_64,
            profile: :standard,
            image_id: "sha256:" <> String.duplicate("a", 64),
            vcpu: 2,
            memory_bytes: 4_294_967_296,
            disk_bytes: 42_949_672_960,
            team_id: nil
          },
          idempotency_key: Ash.UUID.generate()
        },
        actor: actor
      )

    sha = Base.encode16(:crypto.hash(:sha256, "abandoned"), case: :lower)

    assert {:ok, %{id: id}} =
             Marshall.Agents.AttachmentTransfers.begin_upload(
               actor.id,
               thread.id,
               "abandoned",
               9,
               sha
             )

    assert Marshall.Agents.AttachmentTransfers.expire_abandoned(
             DateTime.add(DateTime.utc_now(), 1, :second)
           ) == 1

    assert [%{state: :failed}] = Marshall.Compute.Ledger.read!(Marshall.Agents.Attachment, id: id)

    assert Enum.any?(
             Marshall.Compute.Ledger.read!(Marshall.Agents.AttachmentAudit, attachment_id: id),
             &(is_nil(&1.actor_id) and &1.operation == :expire_upload)
           )

    assert {:ok, %{state: :available}} =
             Marshall.Agents.AttachmentTransfers.upload(
               actor.id,
               thread.id,
               "abandoned",
               "abandoned"
             )
  end
end
