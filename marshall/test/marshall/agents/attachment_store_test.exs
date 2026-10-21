defmodule Marshall.Agents.AttachmentStoreTest do
  use ExUnit.Case, async: false

  alias Marshall.Agents.AttachmentStore

  test "missing and malformed encryption keys refuse writes" do
    previous = Application.get_env(:marshall, AttachmentStore)

    root =
      Path.join(System.tmp_dir!(), "attachment-key-refusal-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:marshall, AttachmentStore),
        else: Application.put_env(:marshall, AttachmentStore, previous)

      File.rm_rf!(root)
    end)

    for key <- [nil, "", <<0>>, :invalid] do
      Application.put_env(:marshall, AttachmentStore, root: root, encryption_key: key)
      assert {:error, :io_error} = AttachmentStore.put("threads/test/refused", "private bytes")
      refute File.exists?(Path.join(root, "threads/test/refused"))
      assert Path.wildcard(Path.join(root, "threads/test/*"), match_dot: true) == []
    end
  end

  test "round trips encrypted bytes without storing plaintext" do
    root =
      Path.join(
        System.tmp_dir!(),
        "marshall-attachment-store-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:marshall, AttachmentStore,
      root: root,
      encryption_key: :crypto.strong_rand_bytes(32)
    )

    on_exit(fn ->
      Application.delete_env(:marshall, AttachmentStore)
      File.rm_rf!(root)
    end)

    bytes = "private attachment bytes"
    key = "threads/thread/attachment"

    assert :ok = AttachmentStore.put(key, bytes)
    assert {:ok, ^bytes} = AttachmentStore.get(key)
    refute File.read!(Path.join(root, key)) =~ bytes
  end
end
