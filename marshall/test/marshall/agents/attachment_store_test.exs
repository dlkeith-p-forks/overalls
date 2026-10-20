defmodule Marshall.Agents.AttachmentStoreTest do
  use ExUnit.Case, async: false

  alias Marshall.Agents.AttachmentStore

  test "round trips encrypted bytes without storing plaintext" do
    root = Path.join(System.tmp_dir!(), "marshall-attachment-store-#{System.unique_integer([:positive])}")
    Application.put_env(:marshall, AttachmentStore, root: root, encryption_key: :crypto.strong_rand_bytes(32))

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
