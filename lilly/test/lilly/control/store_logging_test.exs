defmodule Lilly.Control.StoreLoggingTest do
  use ExUnit.Case, async: false
  alias Lilly.Control.Store
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @metadata [:event, :vm_id, :placement_id, :reason]
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @id)
    %{store: store}
  end

  test "durable intent conflicts emit correlated reasons", %{store: store} do
    current = command(2, @other)
    assert {:ok, :stored} = Store.accept(store, command(1, @id))
    assert {:ok, :stored} = Store.accept(store, current)

    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :generation_conflict} = Store.accept(store, %{current | kind: :delete})

        assert {:error, :operation_conflict} =
                 Store.accept(store, %{current | generation: 3, id: @other})

        foreign = %{current | slot: 3, id: @other, generation: 4}

        assert {:error, :vm_identity_conflict} = Store.accept(store, foreign)
      end)

    assert log =~ "lilly.intent_conflict"
    assert log =~ "vm_id=#{@id}"
    assert log =~ "placement_id=#{@id}"
    assert log =~ "reason=generation_conflict"
    assert log =~ "reason=operation_conflict"
    assert log =~ "reason=vm_identity_conflict"
    assert length(String.split(log, "lilly.intent_conflict")) - 1 == 3
  end

  test "ordinary accepted intent stays silent", %{store: store} do
    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:ok, :stored} = Store.accept(store, command(1, @id))
        assert {:ok, :duplicate} = Store.accept(store, command(1, @id))
        assert {:ok, :stored} = Store.accept(store, command(2, @other))
        assert {:ok, :stale} = Store.accept(store, command(1, @id))
      end)

    refute log =~ "lilly.intent_conflict"
  end

  defp command(generation, id),
    do: %{
      id: id,
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      generation: generation,
      kind: :provision,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    }
end
