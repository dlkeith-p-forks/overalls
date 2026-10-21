defmodule Marshall.Agents.AttachmentHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Agents.{Attachment, AttachmentStore, AttachmentTool, AttachmentTransfers}
  alias Marshall.Compute.Ledger

  @moduletag :hegel_case_sandbox
  @type model :: nil | %{id: String.t(), bytes: binary(), state: :failed | :available}

  # @cc [owner:ghuntley,label:verification] attachment-database-history-oracle
  # Generated upload histories MUST compare durable identity, content and state
  # against an independent model, with fresh database and blob fixtures per case.
  property "upload histories preserve content identity and recover failed writes" do
    commands =
      draw(
        "commands",
        list_of(tuple({member_of(["", "a", "payload"]), boolean()}),
          min_length: 1,
          max_length: 15
        )
      )

    isolate_property_case()
    actor = Marshall.ComputeFixtures.user()

    thread = create_thread(actor)

    previous = Application.get_env(:marshall, AttachmentStore)
    root = Path.join(System.tmp_dir!(), "attachment-history-#{Ecto.UUID.generate()}")
    config = [root: root, encryption_key: :crypto.strong_rand_bytes(32)]

    Hegel.on_cleanup(fn ->
      if previous == nil,
        do: Application.delete_env(:marshall, AttachmentStore),
        else: Application.put_env(:marshall, AttachmentStore, previous)

      File.rm_rf!(root)
    end)

    Enum.reduce(commands, nil, fn {bytes, storage_available}, model ->
      Application.put_env(
        :marshall,
        AttachmentStore,
        if(storage_available, do: config, else: [root: root])
      )

      result = AttachmentTool.upload_bytes(actor.id, thread.id, "history", bytes, %{})
      next = verify_upload(model, bytes, storage_available, result, thread.id)
      [row] = Ledger.read!(Attachment, thread_id: thread.id, idempotency_key: "history")
      assert row.id == next.id
      assert row.state == next.state
      assert row.size_bytes == byte_size(next.bytes)
      assert row.sha256 == Base.encode16(:crypto.hash(:sha256, next.bytes), case: :lower)
      Application.put_env(:marshall, AttachmentStore, config)

      if next.state == :available do
        assert {:ok, stored} = AttachmentStore.get(row.storage_key)
        assert stored == next.bytes
      else
        assert {:error, :attachment_unavailable} = AttachmentTool.download(actor.id, row.id)
      end

      next
    end)
  end

  @spec verify_upload(model(), binary(), boolean(), {:ok, map()} | {:error, atom()}, String.t()) ::
          model()
  defp verify_upload(%{bytes: original} = model, bytes, _available, result, _thread)
       when original != bytes do
    assert result == {:error, :idempotency_conflict}
    model
  end

  defp verify_upload(%{state: :available} = model, _bytes, _available, result, _thread) do
    assert {:ok, %{id: id}} = result
    assert id == model.id
    model
  end

  defp verify_upload(model, bytes, available, result, thread_id) do
    [row] = Ledger.read!(Attachment, thread_id: thread_id, idempotency_key: "history")
    if model, do: assert(row.id == model.id)

    if available do
      assert {:ok, %{id: id}} = result
      assert id == row.id
    else
      assert result == {:error, :attachment_persist_failed}
    end

    %{id: row.id, bytes: bytes, state: if(available, do: :available, else: :failed)}
  end

  @type durable_model :: %{String.t() => %{id: String.t(), bytes: binary()}}

  # @cc [owner:ghuntley,label:verification;security] attachment-audit-failure-atomicity
  # A failed receipt insert at any buffered-upload phase MUST leave no attachment,
  # chunks or receipts; removing the failure MUST permit a fresh complete upload.
  @tag timeout: 120_000
  property "audit insert failures roll back the complete buffered upload" do
    operation = draw("audit phase", member_of([:begin_upload, :put_chunk, :finish_upload]))
    size = draw("content size", member_of([1, 262_145]))
    isolate_property_case()
    actor = Marshall.ComputeFixtures.user()
    thread = create_thread(actor)
    bytes = :binary.copy(<<42>>, size)

    assert {:error, _} =
             Repo.transaction(
               fn ->
                 Ecto.Adapters.SQL.query!(Repo, """
                 CREATE FUNCTION pg_temp.reject_attachment_receipt() RETURNS trigger LANGUAGE plpgsql AS
                 $$ BEGIN RAISE EXCEPTION 'injected attachment receipt failure'; END $$
                 """)

                 Ecto.Adapters.SQL.query!(Repo, """
                 CREATE TRIGGER reject_attachment_receipt BEFORE INSERT ON agent_attachment_audits
                 FOR EACH ROW WHEN (NEW.operation = '#{operation}')
                 EXECUTE FUNCTION pg_temp.reject_attachment_receipt()
                 """)

                 AttachmentTransfers.upload(actor.id, thread.id, "audit-failure", bytes)
               end,
               mode: :savepoint
             )

    assert [] == Ledger.read!(Attachment, thread_id: thread.id)
    assert [] == Ledger.read!(Marshall.Agents.AttachmentAudit, thread_id: thread.id)
    assert [] == Ledger.read!(Marshall.Agents.AttachmentChunk)

    assert {:ok, %{state: :available}} =
             AttachmentTransfers.upload(actor.id, thread.id, "audit-failure", bytes)
  end

  # @cc [owner:ghuntley,label:verification] attachment-durable-history-oracle
  # Generated buffered upload histories MUST preserve the first content identity
  # for each key, refuse conflicting retries and recover exactly the stored bytes.
  property "durable uploads preserve per-key identity across retries and conflicts" do
    commands =
      draw(
        "durable commands",
        list_of(
          tuple(
            {member_of(["first", "second"]), member_of([0, 1, 262_144, 262_145]),
             member_of([0, 255])}
          ),
          min_length: 2,
          max_length: 12
        )
      )

    isolate_property_case()
    actor = Marshall.ComputeFixtures.user()
    thread = create_thread(actor)

    Enum.reduce(commands, %{}, fn {key, size, value}, model ->
      bytes = :binary.copy(<<value>>, size)
      result = AttachmentTransfers.upload(actor.id, thread.id, key, bytes)
      next = verify_durable_upload(model, key, bytes, result)
      expected = Map.fetch!(next, key)
      [row] = Ledger.read!(Attachment, thread_id: thread.id, idempotency_key: key)
      assert row.id == expected.id
      assert row.state == :available
      assert row.storage_key == "chunks:" <> expected.id
      assert row.size_bytes == byte_size(expected.bytes)
      assert row.sha256 == Base.encode16(:crypto.hash(:sha256, expected.bytes), case: :lower)

      {:ok, %{download_token: token}} = AttachmentTool.download(actor.id, row.id)
      assert {:ok, recovered} = AttachmentTool.resolve_download(actor.id, row.id, token)
      assert recovered == expected.bytes
      next
    end)
  end

  @spec verify_durable_upload(
          durable_model(),
          String.t(),
          binary(),
          {:ok, map()} | {:error, term()}
        ) :: durable_model()
  defp verify_durable_upload(model, key, bytes, result) do
    case Map.fetch(model, key) do
      :error ->
        assert {:ok, %{id: id, state: :available}} = result
        Map.put(model, key, %{id: id, bytes: bytes})

      {:ok, %{id: id, bytes: ^bytes}} ->
        assert {:ok, %{id: ^id, state: :available}} = result
        model

      {:ok, _} ->
        assert {:error, :idempotency_conflict} = result
        model
    end
  end

  @spec create_thread(Marshall.Accounts.User.t()) :: Marshall.Threads.Thread.t()
  defp create_thread(actor) do
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

    thread
  end
end
