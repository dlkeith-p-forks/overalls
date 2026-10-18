defmodule Lilly.VM.CheckpointSealingTest do
  # Ownership normalization uses a process-wide service uid cache.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Privilege
  alias Lilly.VM.CheckpointStorage
  @key {Privilege, :service_uid}

  # @cc [owner:ghuntley,label:verification;recovery] interrupted-checkpoint-file-sealing
  # Real file histories interrupted between the two mode changes MUST refuse
  # reuse until both outputs are sealed, including after reopening. This proves
  # local metadata recovery decisions, not native ZFS readonly or KVM behavior.
  property "interrupted output sealing verifies both files before skipping repair" do
    interruption = draw("completed file changes", integer(0..2))
    order = draw("file change order", member_of([["memory", "state"], ["state", "memory"]]))
    bytes = draw("fixture bytes", binary(min_length: 1, max_length: 64))

    corruption =
      draw("sealed output corruption", member_of([:missing, :hardlink, :symlink, :mode]))

    root = Path.join(System.tmp_dir!(), "checkpoint-seal-" <> Lilly.UUID.generate())
    previous = :persistent_term.get(@key, nil)
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
      {:ok, %File.Stat{uid: owner}} = File.lstat(root)
      :persistent_term.put(@key, owner)

      for name <- ["memory", "state"] do
        path = Path.join(root, name)
        File.write!(path, bytes)
        File.chmod!(path, 0o600)
      end

      for name <- Enum.take(order, interruption) do
        File.chmod!(Path.join(root, name), 0o444)
      end

      assert CheckpointStorage.sealed_outputs?(root) == (interruption == 2)

      # Replay completion against the files left by the interrupted history.
      for name <- order do
        File.chmod!(Path.join(root, name), 0o444)
        assert File.read!(Path.join(root, name)) == bytes
      end

      assert CheckpointStorage.sealed_outputs?(root)
      assert {:ok, %File.Stat{mode: memory_mode}} = File.lstat(Path.join(root, "memory"))
      assert {:ok, %File.Stat{mode: state_mode}} = File.lstat(Path.join(root, "state"))
      assert Bitwise.band(memory_mode, 0o777) == 0o444
      assert Bitwise.band(state_mode, 0o777) == 0o444

      state = Path.join(root, "state")

      case corruption do
        :missing ->
          File.rm!(state)

        :hardlink ->
          File.ln!(state, Path.join(root, "state-alias"))

        :symlink ->
          File.rm!(state)
          File.ln_s!(Path.join(root, "memory"), state)

        :mode ->
          File.chmod!(state, 0o600)
      end

      refute CheckpointStorage.sealed_outputs?(root)
    after
      if previous == nil,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, previous)

      File.rm_rf!(root)
    end
  end
end
